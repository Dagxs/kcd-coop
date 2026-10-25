// KCD1 co-op loader (coop-anything). Proxy dinput8.dll placed next to KingdomCome.exe in a TEST COPY.
// Build target: KCD 1.9.8 Steam, WHGame.dll SHA-256 cf9f6dc384edcf35c20647a912745ddb8adb5ba65953e329c24e89dd9c4381aa
//
// v3.5: script bridge + puppet + UDP position sync between two games.
//  - DLL -> game: CXConsole::ExecuteString(cmd, silent, defer=true) with "#<lua>" commands
//    (deferred, so the game runs them on its main thread next frame).
//  - game -> DLL: Lua writes a string into a console variable; DLL reads it via ICVar::GetString.
//  - Logs the local player's position once a second to kcdcoop.log (milestone: read player state).
//  - Listen-server network patches from v1 are OFF unless a file "kcdcoop_netpatch" exists in the game root.
// Every address is verified against the expected bytes / vtable before use; on mismatch it does nothing.
// Remove this DLL to undo.
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

static char g_role = 'A';  // 'A' = KingdomCome.exe, 'B' = KingdomCome2.exe (second copy on one PC)

typedef HRESULT(WINAPI *DI8Create_t)(HINSTANCE, DWORD, REFIID, LPVOID *, LPUNKNOWN);
static DI8Create_t g_real = NULL;
static volatile LONG g_started = 0;
static unsigned char *g_base = NULL;

// ---- RVAs in WHGame.dll (this build only) ----
#define RVA_GENV_PCONSOLE   0x29D1768u  // IConsole* gEnv->pConsole (static global in the monolithic build)
#define RVA_EXECUTESTRING   0xEC6920u   // CXConsole::ExecuteString(const char*, bool bSilent, bool bDefer)
#define VT_GETCVAR          (0xB8 / 8)  // IConsole::GetCVar(const char*)
#define VT_CVAR_GETSTRING   (0x28 / 8)  // ICVar::GetString()
#define VT_CVAR_SETSTRING   (0x48 / 8)  // ICVar::Set(const char*)

static const unsigned char kExecPrologue[] = {0x48,0x89,0x5C,0x24,0x10,0x48,0x89,0x74,0x24,0x18,0x55,0x57,0x41,0x56};

typedef void  (*ExecStr_t)(void *self, const char *cmd, char silent, char defer);
typedef void *(*GetCVar_t)(void *self, const char *name);
typedef const char *(*CVarGetStr_t)(void *cvar);
typedef void  (*CVarSetStr_t)(void *cvar, const char *val);

static void coop_log(const char *fmt, ...) {
    FILE *f = fopen("kcdcoop.log", "a");
    if (!f) return;
    SYSTEMTIME t; GetLocalTime(&t);
    fprintf(f, "%02d:%02d:%02d [%c] ", t.wHour, t.wMinute, t.wSecond, g_role);
    va_list ap; va_start(ap, fmt); vfprintf(f, fmt, ap); va_end(ap);
    fputc('\n', f);
    fclose(f);
}

// ---------------- v1 network patches (optional) ----------------
typedef struct { DWORD rva; unsigned char orig[8]; unsigned char patch[2]; const char *what; } Patch;
static const Patch kPatches[] = {
    { 0xC32D99, {0x38,0x0D,0x32,0xEB,0xD9,0x01,0x74,0x10}, {0xEB,0x16}, "conn-setup -> server handler" },
    { 0xC32E58, {0x38,0x0D,0x73,0xEA,0xD9,0x01,0x74,0x27}, {0xEB,0x2D}, "keyexchange 0x8A -> normal handler" },
};
static void apply_net_patches(void) {
    if (GetFileAttributesA("kcdcoop_netpatch") == INVALID_FILE_ATTRIBUTES) return;
    for (size_t i = 0; i < sizeof(kPatches) / sizeof(kPatches[0]); i++)
        if (memcmp(g_base + kPatches[i].rva, kPatches[i].orig, sizeof(kPatches[i].orig)) != 0) {
            coop_log("net patch MISMATCH at +%#lx; not patching", kPatches[i].rva); return;
        }
    for (size_t i = 0; i < sizeof(kPatches) / sizeof(kPatches[0]); i++) {
        unsigned char *at = g_base + kPatches[i].rva; DWORD old;
        VirtualProtect(at, 2, PAGE_EXECUTE_READWRITE, &old);
        at[0] = kPatches[i].patch[0]; at[1] = kPatches[i].patch[1];
        VirtualProtect(at, 2, old, &old);
        FlushInstructionCache(GetCurrentProcess(), at, 2);
        coop_log("net patch applied +%#lx: %s", kPatches[i].rva, kPatches[i].what);
    }
}

// ---------------- script bridge ----------------
static void *g_console = NULL;
static ExecStr_t g_exec = NULL;

static int readable(const void *p, size_t n) {
    MEMORY_BASIC_INFORMATION mbi;
    if (!p || !VirtualQuery(p, &mbi, sizeof(mbi))) return 0;
    if (mbi.State != MEM_COMMIT || (mbi.Protect & (PAGE_NOACCESS | PAGE_GUARD))) return 0;
    return (const char *)p + n <= (const char *)mbi.BaseAddress + mbi.RegionSize;
}

// Console "#lua" commands only reach the script system when ISystem::IsDevMode() is true.
// Skip just that check (je -> nop nop) so deferred "#..." commands run on the main thread.
static int patch_lua_devcheck(void) {
    static const unsigned char orig[] = {0xFF,0x90,0x60,0x03,0x00,0x00,0x84,0xC0,0x74,0x5A};
    unsigned char *at = g_base + 0xEC7026;
    if (memcmp(at, orig, sizeof(orig)) != 0) {
        if (at[8] == 0x90 && at[9] == 0x90) return 1;
        coop_log("lua devcheck bytes mismatch: not patching"); return 0;
    }
    DWORD old;
    if (!VirtualProtect(at + 8, 2, PAGE_EXECUTE_READWRITE, &old)) return 0;
    at[8] = 0x90; at[9] = 0x90;
    VirtualProtect(at + 8, 2, old, &old);
    FlushInstructionCache(GetCurrentProcess(), at + 8, 2);
    coop_log("lua devcheck skipped (+0xec702e)");
    return 1;
}

static int bridge_init(void) {
    void **slot = (void **)(g_base + RVA_GENV_PCONSOLE);
    void *con = *slot;
    if (!con || !readable(con, 8)) return 0;
    void **vt = *(void ***)con;
    if (!readable(vt, 8 * 200)) return 0;
    if (memcmp(g_base + RVA_EXECUTESTRING, kExecPrologue, sizeof(kExecPrologue)) != 0) {
        coop_log("ExecuteString prologue mismatch: wrong build? bridge disabled"); return -1;
    }
    int idx = -1;
    for (int i = 0; i < 200; i++) if (vt[i] == (void *)(g_base + RVA_EXECUTESTRING)) { idx = i; break; }
    if (idx < 0) { coop_log("ExecuteString not in console vtable: bridge disabled"); return -1; }
    g_console = con;
    g_exec = (ExecStr_t)vt[idx];
    coop_log("bridge ready: console=%p ExecuteString=vtable[%d]", con, idx);
    return 1;
}

static void *cvar(const char *name) {
    void **vt = *(void ***)g_console;
    return ((GetCVar_t)vt[VT_GETCVAR])(g_console, name);
}
static const char *cvar_str(void *cv) { void **vt = *(void ***)cv; return ((CVarGetStr_t)vt[VT_CVAR_GETSTRING])(cv); }
static void cvar_set(void *cv, const char *v) { void **vt = *(void ***)cv; ((CVarSetStr_t)vt[VT_CVAR_SETSTRING])(cv, v); }

static void run_lua(const char *lua) {  // deferred: executes on the game's main thread next frame
    static char buf[16384];  // only called from the worker thread
    snprintf(buf, sizeof(buf), "#%s", lua);
    g_exec(g_console, buf, 1, 1);
}

// Lua that publishes the local player's state into a string cvar we read back.
// cl_serveraddr is unused in single player (it is the "connect to" address).
static const char *kPublishLua =
    "if player then local p=player:GetWorldPos(); local a=player:GetWorldAngles(); "
    "local d = 0 pcall(function() if player.human:IsWeaponDrawn() then d = 1 end end) "
    "System.SetCVar('cl_serveraddr', string.format('P %.2f %.2f %.2f %.3f %d', p.x, p.y, p.z, a.z, d)) "
    "else System.SetCVar('cl_serveraddr', 'noplayer') end";

// Game-side half (puppet NPC, Henry look, animation, CoopSetRemote) lives in lua/coop_core.lua,
// embedded at build time as kCoreLua. It only defines what is missing, so it is safe to re-run.
#include "coop_core_lua.h"
static void run_lua(const char *lua);
static void run_core(void) { for (int i = 0; i < CORE_LUA_CHUNKS; i++) run_lua(kCoreLua[i]); }

// ---------------- gear (v3.4) ----------------
// The engine's internal equip routine (C_ActorEquipmentHandler-like object in rcx, item WUID in rdx).
// Worn clothing is an MSVC std::unordered_set<WUID> at handler+0x10 (list head at +0x18, size at +0x20,
// nodes {next, prev, wuid}); equip inserts into it, unequip erases (see NOTES.md).
#define RVA_EQUIP_INTERNAL 0x44D6C8u
static const unsigned char kEquipPrologue[17] = {0x48,0x8B,0xC4,0x48,0x89,0x58,0x08,0x48,0x89,0x70,0x18,
                                                 0x48,0x89,0x78,0x20,0x41,0x56};
typedef unsigned long long (*EquipFn)(void *handler, unsigned long long wuid, unsigned long long r8, unsigned long long r9);
static EquipFn g_equip_tramp = NULL;
static volatile unsigned long long g_probe_wuid = 0;
static void *volatile g_player_handler = NULL;

static unsigned long long hook_equip_internal(void *h, unsigned long long w, unsigned long long a3, unsigned long long a4) {
    if (g_probe_wuid && w == g_probe_wuid) { g_player_handler = h; g_probe_wuid = 0; }
    return g_equip_tramp(h, w, a3, a4);
}

// Gear lists come from the network: allow only item-class GUID characters before they go into Lua.
static int gear_list_safe(const char *g) {
    for (; *g; g++) if (!((*g >= '0' && *g <= '9') || (*g >= 'a' && *g <= 'f') || (*g >= 'A' && *g <= 'F') || *g == '-' || *g == ',')) return 0;
    return 1;
}

static int install_equip_hook(void) {
    unsigned char *target = g_base + RVA_EQUIP_INTERNAL;
    if (memcmp(target, kEquipPrologue, sizeof(kEquipPrologue)) != 0) { coop_log("equip hook: prologue mismatch, gear sync off"); return 0; }
    unsigned char *tr = (unsigned char *)VirtualAlloc(NULL, 64, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
    if (!tr) return 0;
    memcpy(tr, target, 17);                                  // relocatable: no rip-relative operands
    tr[17] = 0xFF; tr[18] = 0x25; memset(tr + 19, 0, 4);      // jmp [rip+0]
    unsigned long long back = (unsigned long long)(target + 17);
    memcpy(tr + 23, &back, 8);
    g_equip_tramp = (EquipFn)tr;
    unsigned char patch[17];
    patch[0] = 0xFF; patch[1] = 0x25; memset(patch + 2, 0, 4);
    unsigned long long hk = (unsigned long long)hook_equip_internal;
    memcpy(patch + 6, &hk, 8);
    patch[14] = patch[15] = patch[16] = 0x90;
    DWORD old;
    if (!VirtualProtect(target, 17, PAGE_EXECUTE_READWRITE, &old)) return 0;
    memcpy(target, patch, 17);
    VirtualProtect(target, 17, old, &old);
    FlushInstructionCache(GetCurrentProcess(), target, 17);
    coop_log("equip hook installed at +%#x", RVA_EQUIP_INTERNAL);
    return 1;
}

static int readable(const void *p, size_t n);
static int read_worn(unsigned long long *out, int max) {
    unsigned char *h = (unsigned char *)g_player_handler;
    if (!h || !readable(h + 0x10, 0x18)) return -1;
    void **head = *(void ***)(h + 0x18);
    unsigned long long n = *(unsigned long long *)(h + 0x20);
    if (n > 64 || !readable(head, 0x18)) return -1;
    int c = 0;
    void **node = (void **)head[0];
    while (node && node != head && c < max) {
        if (!readable(node, 0x18)) return -1;
        out[c++] = *(unsigned long long *)((unsigned char *)node + 0x10);
        node = (void **)node[0];
    }
    // weapon slots: 12 WUIDs at handler+0x50 (up to the counter at +0xB0); empty = global at +0x300F8D8
    unsigned long long empty = *(unsigned long long *)(g_base + 0x300F8D8);
    if (readable(h + 0x50, 12 * 8))
        for (int i = 0; i < 12 && c < max; i++) {
            unsigned long long v = *(unsigned long long *)(h + 0x50 + i * 8);
            if (v && v != empty) out[c++] = v;
        }
    return c;
}

// ---------------- transport (plain UDP, v3) ----------------
// Defaults for two copies on one PC: A binds 64200 and sends to 127.0.0.1:64201, B the reverse.
// Optional kcdcoop_<role>.ini in the game root overrides: "bind=<port>" and "peer=<ip>:<port>".
static int g_bind = 0;
static char g_peer_ip[64] = "127.0.0.1";
static int g_peer_port = 0;

static void net_config(void) {
    g_bind = g_role == 'A' ? 64200 : 64201;
    g_peer_port = g_role == 'A' ? 64201 : 64200;
    char name[32];
    snprintf(name, sizeof(name), "kcdcoop_%c.ini", g_role);
    FILE *f = fopen(name, "r");
    if (!f) return;
    char line[128];
    while (fgets(line, sizeof(line), f)) {
        int p; char ip[64];
        if (sscanf(line, "bind=%d", &p) == 1) g_bind = p;
        else if (sscanf(line, "peer=%63[^:]:%d", ip, &p) == 2) { strcpy(g_peer_ip, ip); g_peer_port = p; }
    }
    fclose(f);
}

static SOCKET net_open(void) {
    WSADATA w;
    if (WSAStartup(MAKEWORD(2, 2), &w) != 0) { coop_log("WSAStartup failed"); return INVALID_SOCKET; }
    net_config();
    SOCKET s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (s == INVALID_SOCKET) { coop_log("socket failed %d", WSAGetLastError()); return s; }
    struct sockaddr_in a = {0};
    a.sin_family = AF_INET; a.sin_port = htons((u_short)g_bind); a.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(s, (struct sockaddr *)&a, sizeof(a)) != 0) {
        coop_log("bind %d failed %d", g_bind, WSAGetLastError()); closesocket(s); return INVALID_SOCKET;
    }
    u_long nb = 1; ioctlsocket(s, FIONBIO, &nb);
    coop_log("net: role %c bound udp %d, peer %s:%d", g_role, g_bind, g_peer_ip, g_peer_port);
    return s;
}

static void net_peer(struct sockaddr_in *p) {
    memset(p, 0, sizeof(*p));
    p->sin_family = AF_INET; p->sin_port = htons((u_short)g_peer_port);
    inet_pton(AF_INET, g_peer_ip, &p->sin_addr);
}

static DWORD WINAPI worker(LPVOID unused) {
    (void)unused;
    while (!(g_base = (unsigned char *)GetModuleHandleA("WHGame.dll"))) Sleep(100);
    Sleep(500);
    apply_net_patches();
    if (!patch_lua_devcheck()) { coop_log("bridge disabled"); return 0; }

    int r = 0;
    for (int i = 0; i < 1200 && r == 0; i++) { Sleep(250); r = bridge_init(); }
    if (r != 1) { coop_log("bridge not started (%d)", r); return 0; }

    // Lua needs con_restricted 0 when not typed into the console.
    Sleep(3000);
    void *cr = cvar("con_restricted");
    if (cr) { cvar_set(cr, "0"); coop_log("con_restricted -> %s", cvar_str(cr)); }
    run_lua("System.LogAlways('[coop] hello from the kcdcoop loader')");
    run_core();
    int gear_ok = install_equip_hook();
    int fake = GetFileAttributesA("kcdcoop_fake") != INVALID_FILE_ATTRIBUTES;
    coop_log("fake follow test: %s", fake ? "on" : "off");

    SOCKET s = net_open();
    struct sockaddr_in peer;
    net_peer(&peer);

    unsigned long sent = 0, recvd = 0, bad = 0, cmds = 0;
    char lastRemote[128] = "";
    DWORD lastRecvTick = 0, prevPktTick = 0;
    int haveTarget = 0, haveShown = 0;
    float tx = 0, ty = 0, tz = 0, tr = 0;      // newest received state
    float px = 0, py = 0, pz = 0;              // previous received position (for speed)
    float sx = 0, sy = 0, sz = 0, sr = 0;      // smoothed state shown on the puppet
    float speed = 0;
    int tdrawn = 0;
    char cmdfile[32];
    snprintf(cmdfile, sizeof(cmdfile), "kcdcoop_cmd_%c.lua", g_role);
    static char myGear[1200] = "", lastWornHex[1200] = "", remoteGear[1200] = "", appliedGear[1200] = "";
    int haveMyGear = 0, probes = 0;

    for (int tick = 0;; tick++) {
        Sleep(33);
        if (tick % 150 == 0) run_core();  // (re)defines the core functions if missing

        // 0) command file: run a one-off Lua chunk dropped into the game root, then delete it
        if (tick % 15 == 0) {
            FILE *cf = fopen(cmdfile, "rb");
            if (cf) {
                static char chunk[15000];
                size_t n = fread(chunk, 1, sizeof(chunk) - 1, cf);
                fclose(cf);
                chunk[n] = 0;
                for (size_t i = 0; i < n; i++) if (chunk[i] == '\r' || chunk[i] == '\n' || chunk[i] == '\t') chunk[i] = ' ';
                DeleteFileA(cmdfile);
                run_lua(chunk);
                coop_log("ran %s (%u bytes)", cmdfile, (unsigned)n);
                cmds++;
            }
        }

        // 1) every 3rd tick (~10 Hz): publish + read our own player state, send it
        if (tick % 3 == 0) {
            run_lua(kPublishLua);
            void *cv = cvar("cl_serveraddr");
            if (cv && s != INVALID_SOCKET) {
                char now[128];
                strncpy(now, cvar_str(cv), sizeof(now) - 1); now[sizeof(now) - 1] = 0;
                if (now[0] == 'P' && now[1] == ' ') {
                    char pkt[160];
                    int n = snprintf(pkt, sizeof(pkt), "KCDCOOP1 %s", now);
                    if (sendto(s, pkt, n, 0, (struct sockaddr *)&peer, sizeof(peer)) == n) sent++;
                }
            }
        }

        // 2) drain incoming packets, keep the newest valid one
        if (s != INVALID_SOCKET) {
            static char buf[1400];
            for (;;) {
                int n = recv(s, buf, sizeof(buf) - 1, 0);
                if (n <= 0) break;
                buf[n] = 0;
                float x, y, z, r;
                int dr = 0;
                if (sscanf(buf, "KCDCOOP1 P %f %f %f %f %d", &x, &y, &z, &r, &dr) >= 4) {
                    tdrawn = dr ? 1 : 0;
                    DWORD now = GetTickCount();
                    if (haveTarget && now - prevPktTick > 0) {
                        float dx = x - px, dy = y - py;
                        float inst = sqrtf(dx * dx + dy * dy) / ((now - prevPktTick) / 1000.0f);
                        if (inst < 30.0f) speed = speed * 0.5f + inst * 0.5f;  // ignore teleports
                    }
                    px = x; py = y; pz = z; prevPktTick = now;
                    tx = x; ty = y; tz = z; tr = r; haveTarget = 1; recvd++;
                    lastRecvTick = now;
                    strncpy(lastRemote, buf + 9, sizeof(lastRemote) - 1);
                } else if (strncmp(buf, "KCDCOOP1 G", 10) == 0) {
                    const char *g = buf + 10;
                    if (*g == ' ') g++;
                    if (gear_list_safe(g)) { strncpy(remoteGear, g, sizeof(remoteGear) - 1); recvd++; }
                    else bad++;
                } else bad++;
            }
        }
        if (remoteGear[0] || strcmp(remoteGear, appliedGear) != 0) {
            if (strcmp(remoteGear, appliedGear) != 0) {
                static char lua[1400];
                snprintf(lua, sizeof(lua), "CoopDressRemote('%s')", remoteGear);
                run_lua(lua);
                strcpy(appliedGear, remoteGear);
                coop_log("gear: dressing stand-in with [%s]", remoteGear);
            }
        }

        // 3) ~30 Hz: move the puppet smoothly toward the newest state
        if (haveTarget) {
            float dx = tx - sx, dy = ty - sy, dz = tz - sz;
            if (!haveShown || dx * dx + dy * dy + dz * dz > 25.0f) {  // first frame or >5 m: snap
                sx = tx; sy = ty; sz = tz; sr = tr; haveShown = 1;
            } else {
                const float k = 0.35f;
                sx += dx * k; sy += dy * k; sz += dz * k;
                float dr = tr - sr;
                while (dr > 3.14159265f) dr -= 6.2831853f;
                while (dr < -3.14159265f) dr += 6.2831853f;
                sr += dr * k;
            }
            if (GetTickCount() - lastRecvTick > 1500) speed = 0;  // remote stopped sending
            char lua[192];
            snprintf(lua, sizeof(lua), "CoopSetRemote(%.3f, %.3f, %.3f, %.4f, %.2f, %d)", sx, sy, sz, sr, speed, tdrawn);
            run_lua(lua);
        } else if (fake && tick % 3 == 0) {
            run_lua("CoopFakeFollow()");
        }

        // 4) gear: find the player's equipment handler once (probe), then report worn items each second
        if (gear_ok && !g_player_handler && probes < 5) {
            if (tick % 60 == 10) run_lua("CoopProbePublish()");
            if (tick % 60 == 20) {
                void *sv = cvar("sv_servername");
                unsigned long long w = 0;
                if (sv && sscanf(cvar_str(sv), "W userdata: %llx", &w) == 1 && w) {
                    g_probe_wuid = w;
                    run_lua("CoopProbeEquip()");
                    if (++probes == 5) coop_log("gear: probe did not find the equipment handler, gear sync off");
                }
            }
            if (tick % 60 == 30 && g_player_handler) coop_log("gear: player equipment handler %p", g_player_handler);
        } else if (gear_ok && g_player_handler) {
            if (tick % 30 == 5) {
                unsigned long long worn[64];
                int n = read_worn(worn, 64);
                if (n >= 0) {
                    char hex[1200] = "";
                    size_t len = 0;
                    for (int i = 0; i < n && len < sizeof(hex) - 20; i++) len += snprintf(hex + len, sizeof(hex) - len, "%llx ", worn[i]);
                    if (strcmp(hex, lastWornHex) != 0 || !haveMyGear) {
                        static char lua[1400];
                        snprintf(lua, sizeof(lua), "CoopReportWorn('%s')", hex);
                        run_lua(lua);
                        strcpy(lastWornHex, hex);
                    }
                } else if (tick % 300 == 5) coop_log("gear: worn set unreadable");
            }
            if (tick % 30 == 12) {
                void *sv = cvar("sv_servername");
                const char *v = sv ? cvar_str(sv) : NULL;
                if (v && v[0] == 'G' && (v[1] == ' ' || v[1] == 0)) {
                    const char *g = v[1] ? v + 2 : v + 1;
                    if (strcmp(g, myGear) != 0 || !haveMyGear) {
                        strncpy(myGear, g, sizeof(myGear) - 1);
                        haveMyGear = 1;
                        coop_log("gear: wearing [%s]", myGear);
                    }
                }
            }
        }
        if (haveMyGear && s != INVALID_SOCKET && tick % 60 == 40) {  // (re)send gear every 2 s
            static char pkt[1300];
            int n = snprintf(pkt, sizeof(pkt), "KCDCOOP1 G %s", myGear);
            if (n > 0 && n < (int)sizeof(pkt)) sendto(s, pkt, n, 0, (struct sockaddr *)&peer, sizeof(peer));
        }

        if (tick % 150 == 0)
            coop_log("net: sent=%lu recv=%lu bad=%lu cmds=%lu speed=%.2f remote=%s", sent, recvd, bad, cmds, speed,
                 lastRemote[0] ? lastRemote : "-");
    }
}

// ---------------- dinput8 forwarding ----------------
static int load_real(void) {
    if (g_real) return 1;
    char path[MAX_PATH];
    UINT n = GetSystemDirectoryA(path, MAX_PATH);
    if (!n || n > MAX_PATH - 16) return 0;
    lstrcatA(path, "\\dinput8.dll");
    HMODULE r = LoadLibraryA(path);
    if (!r) { coop_log("could not load %s (%lu)", path, GetLastError()); return 0; }
    g_real = (DI8Create_t)GetProcAddress(r, "DirectInput8Create");
    return g_real != NULL;
}

__declspec(dllexport) HRESULT WINAPI DirectInput8Create(HINSTANCE hinst, DWORD ver, REFIID riid, LPVOID *out, LPUNKNOWN outer) {
    if (!load_real()) return E_FAIL;
    return g_real(hinst, ver, riid, out, outer);
}

BOOL WINAPI DllMain(HINSTANCE h, DWORD reason, LPVOID r) {
    (void)r;
    if (reason == DLL_PROCESS_ATTACH && InterlockedCompareExchange(&g_started, 1, 0) == 0) {
        DisableThreadLibraryCalls(h);
        char exe[MAX_PATH] = "";
        GetModuleFileNameA(NULL, exe, MAX_PATH);
        const char *b = strrchr(exe, '\\'); b = b ? b + 1 : exe;
        if (_stricmp(b, "KingdomCome2.exe") == 0) g_role = 'B';
        coop_log("kcdcoop loader v3.5 attached (%s)", b);
        HANDLE t = CreateThread(NULL, 0, worker, NULL, 0, NULL);
        if (t) CloseHandle(t);
    }
    return TRUE;
}
