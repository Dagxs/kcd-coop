"""Run coop_core.lua in two fake Lua worlds (host A, client B) and check enemy sync end to end."""
import pathlib, sys
from lupa import LuaRuntime
root = pathlib.Path(__file__).resolve().parent.parent
core = (root / "lua" / "coop_core.lua").read_text()
fake = (root / "tests" / "fake_world.lua").read_text()

def world(role):
    L = LuaRuntime()
    W = L.execute(fake)
    L.execute(core)
    L.execute(f"CoopRole = '{role}'")
    return L, W

A, WA = world("A"); B, WB = world("B")
A.execute("player = nil"); 
pa = WA.mk("player", "Player", 0, 0, 0, False); A.globals().player = pa
pb = WB.mk("player", "Player", 2, 0, 0, False); B.globals().player = pb
bandit = WA.mk("SpawnedEnemy_01", "NPC", 5, 0, 0, True)
bandit.drawn = True; bandit.state = "CombatAttack"
# a local hostile on B that host does not know: must be hidden
lb = WB.mk("ska_localbandit", "NPC", 6, 1, 0, True)
fails = []
def check(cond, msg):
    print(("PASS " if cond else "FAIL ") + msg); 
    if not cond: fails.append(msg)

def cycle(seq):
    A.execute(f"CoopFlush({seq})"); B.execute(f"CoopFlush({seq})")
    pa_out = A.eval("CVAR.sv_password"); pb_out = B.eval("CVAR.sv_password")
    B.globals().CoopRecv(pa_out.split("|", 1)[1]); A.globals().CoopRecv(pb_out.split("|", 1)[1])
    WA.tick(0.1); WB.tick(0.1)

for i in range(5): cycle(i)
proxy = B.eval("CoopEn['SpawnedEnemy_01'] and CoopEn['SpawnedEnemy_01'].e")
check(proxy is not None, "client spawned a proxy for the host's bandit")
check(proxy is not None and abs(proxy.pos.x - 5) < 0.5, "proxy sits at the host bandit's position")
bandit.pos = {"x": 8, "y": 0, "z": 0} if False else A.eval("{x=8,y=0,z=0}")
for i in range(10): cycle(10 + i)
check(abs(proxy.pos.x - 8) < 0.3, "proxy followed the bandit's move")
check(B.eval("function(e) return e.hidden end")(lb) == True, "client hid its own local bandit")
# client hits proxy
proxy.hp = 70
for i in range(3): cycle(30 + i)
check(bandit.hp < 75, f"host bandit took the client's damage (hp={bandit.hp})")
# host stand-in got hit: client player takes damage
A.execute("CoopEnsurePuppet(2,0,0)"); A.eval("CoopP").hp = 85
for i in range(2): cycle(40 + i)
check(pb.hp < 90, f"client player took the stand-in's damage (hp={pb.hp})")
# bandit dies on host
bandit.hp = 0
for i in range(3): cycle(50 + i)
check(B.eval("CoopEn['SpawnedEnemy_01'] and CoopEn['SpawnedEnemy_01'].dead") is True, "client proxy died with the host bandit")
# host stops sending (bandit removed): dead proxy released after 3 s and stays
A.eval("System.RemoveEntity")(bandit.id)
for i in range(40): cycle(60 + i)
check(B.eval("CoopEn['SpawnedEnemy_01']") is None, "proxy entry released when host stops sending")
print("FAILED" if fails else "ALL PASSED", len(fails))
sys.exit(1 if fails else 0)
