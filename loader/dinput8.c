// KCD1 co-op loader (coop-anything). Proxy dinput8.dll placed next to KingdomCome.exe in a TEST COPY.
// Build target: KCD 1.9.8 Steam, WHGame.dll SHA-256 cf9f6dc384edcf35c20647a912745ddb8adb5ba65953e329c24e89dd9c4381aa
//
// v3.1: script bridge + puppet + UDP position sync between two games.
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
    "System.SetCVar('cl_serveraddr', string.format('P %.2f %.2f %.2f %.3f', p.x, p.y, p.z, a.z)) "
    "else System.SetCVar('cl_serveraddr', 'noplayer') end";

// Puppet (stand-in for the remote player). Defined once; CoopSetRemote() moves it, respawning it
// if the level was reloaded. For the solo test, CoopFakeFollow() feeds it the local player's
// position shifted 2 m sideways. No semicolons: the console treats ';' as a command separator.
static const char *kPuppetLua =
    "if not CoopSetRemote then "
    "function CoopEnsurePuppet(x,y,z) "
    "  if CoopP and CoopP.id and System.GetEntity(CoopP.id) then return CoopP end "
    "  local e = System.SpawnEntity({class='BasicEntity', name='coop_puppet', position={x=x,y=y,z=z}}) "
    "  if not e then System.LogAlways('[coop] puppet spawn FAILED') CoopP=nil return nil end "
    "  local ok = pcall(function() e:LoadCharacter(0, 'objects/characters/humans/skeleton/male.cdf') end) "
    "  System.LogAlways('[coop] puppet spawned id=' .. tostring(e.id) .. ' character=' .. tostring(ok)) "
    "  CoopP = e CoopAnimCur = nil return e "
    "end "
    "function CoopSetRemote(x,y,z,rz,spd) "
    "  local e = CoopEnsurePuppet(x,y,z) if not e then return end "
    "  e:SetWorldPos({x=x,y=y,z=z}) e:SetWorldAngles({x=0,y=0,z=rz}) "
    "  if CoopAnimate then pcall(CoopAnimate, e, spd or 0) end "
    "end "
    "function CoopFakeFollow() "
    "  if not player then return end "
    "  local p = player:GetWorldPos() local a = player:GetWorldAngles() "
    "  CoopSetRemote(p.x + 2, p.y, p.z, a.z, 0) "
    "end "
    "System.LogAlways('[coop] puppet functions defined') "
    "end";

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
    run_lua(kPuppetLua);
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
    char cmdfile[32];
    snprintf(cmdfile, sizeof(cmdfile), "kcdcoop_cmd_%c.lua", g_role);

    for (int tick = 0;; tick++) {
        Sleep(33);
        if (tick % 150 == 0) run_lua(kPuppetLua);  // defines the puppet functions if missing

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
            char buf[256];
            for (;;) {
                int n = recv(s, buf, sizeof(buf) - 1, 0);
                if (n <= 0) break;
                buf[n] = 0;
                float x, y, z, r;
                if (sscanf(buf, "KCDCOOP1 P %f %f %f %f", &x, &y, &z, &r) == 4) {
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
                } else bad++;
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
            snprintf(lua, sizeof(lua), "CoopSetRemote(%.3f, %.3f, %.3f, %.4f, %.2f)", sx, sy, sz, sr, speed);
            run_lua(lua);
        } else if (fake && tick % 3 == 0) {
            run_lua("CoopFakeFollow()");
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
        coop_log("kcdcoop loader v3.1 attached (%s)", b);
        HANDLE t = CreateThread(NULL, 0, worker, NULL, 0, NULL);
        if (t) CloseHandle(t);
    }
    return TRUE;
}
