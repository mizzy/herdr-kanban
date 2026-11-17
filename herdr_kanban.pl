#!/usr/bin/env perl
# Agent board for herdr. Run: perl herdr_kanban.pl [port]
use strict;
use warnings;
use HTTP::Daemon;
use HTTP::Response;
use JSON::PP;
use URI;

my $port = shift // 8765;
my %since;    # pane_id => [status, epoch] : herdr has no timestamps, so track status changes ourselves

sub herdr { open(my $fh, '-|', 'herdr', @_) or return ''; local $/; my $out = <$fh> // ''; close $fh; $out }

sub agents {
    my $list = eval { decode_json(herdr(qw(agent list)))->{result}{agents} } || [];
    my $now  = time;
    for my $a (@$list) {
        # herdr calls a Claude idle once its turn ends, even while background shells/monitors it will
        # wake up on are still running. Claude's footer lists them ("· 1 shell · ... ↓ to manage").
        if (($a->{agent} // '') eq 'claude' && ($a->{agent_status} // '') =~ /^(idle|done)$/) {
            my ($footer) = grep /to manage/, split /\n/, herdr(qw(agent read), $a->{pane_id}, qw(--lines 3));
            my @bg = ($footer // '') =~ /(\d+ (?:shell|monitor)s?)\b/g;
            @$a{qw(agent_status background)} = ('working', join ', ', @bg) if @bg;
        }
        my $s = $since{ $a->{pane_id} };
        $since{ $a->{pane_id} } = $s = [ $a->{agent_status} // '', $now ]
            if !$s || $s->[0] ne ($a->{agent_status} // '');
        $a->{since} = $s->[1];
    }
    $list;
}

my $page = do { local $/; <DATA> };
my $d = HTTP::Daemon->new(LocalAddr => '127.0.0.1', LocalPort => $port, ReuseAddr => 1) or die "listen: $!";
print "http://127.0.0.1:$port\n";

# ponytail: single-threaded, one request per connection (no keep-alive, or one open tab would
# block every other client); fork per connection if a slow herdr call ever stalls the board
while (my $c = $d->accept) {
    $c->timeout(5);    # drop idle (pre)connections instead of blocking the loop
    if (my $r = $c->get_request) {
        $c->force_last_request;
        my $u    = URI->new($r->uri);
        my %q    = $u->query_form;
        my $pane = ($q{pane} // '') =~ /^[\w:]+$/ ? $q{pane} : undef;
        my $p    = $u->path;
        my ($code, $type, $body) = (404, 'text/plain', 'not found');
        if    ($p eq '/' && $r->method eq 'GET')             { ($code, $type, $body) = (200, 'text/html; charset=utf-8', $page) }
        elsif ($p eq '/agents')                              { ($code, $type, $body) = (200, 'application/json', encode_json(agents())) }
        elsif ($p eq '/read' && $pane)                       { ($code, $type, $body) = (200, 'text/plain; charset=utf-8', herdr(qw(agent read), $pane, qw(--lines 40))) }
        elsif ($p eq '/focus' && $pane && $r->method eq 'POST') { herdr(qw(agent focus), $pane); ($code, $body) = (204, '') }
        $c->send_response(HTTP::Response->new($code, undef, [ 'Content-Type' => $type ], $body));
    }
    $c->close;
}

__DATA__
<!doctype html><html lang="ja"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>herdr board</title>
<link href="https://fonts.googleapis.com/css2?family=Geist:wght@400;500&family=Geist+Mono:wght@400;500&display=swap" rel="stylesheet">
<style>
:root{
 --paper:oklch(16% 0.012 260);--paper-2:oklch(20% 0.014 260);--ink:oklch(93% 0.005 260);--ink-2:oklch(68% 0.012 260);
 --ink-3:oklch(52% 0.012 260);--rule:oklch(26% 0.014 260);
 --need:oklch(78% 0.16 70);--work:oklch(72% 0.13 230);--idle:oklch(55% 0.01 260);--focus:oklch(80% 0.12 230);
 --font-body:"Geist",-apple-system,system-ui,sans-serif;--font-mono:"Geist Mono",ui-monospace,monospace}
@media (prefers-color-scheme:light){:root{
 --paper:oklch(98% 0.004 260);--paper-2:oklch(94.5% 0.006 260);--ink:oklch(22% 0.012 260);--ink-2:oklch(45% 0.012 260);
 --ink-3:oklch(56% 0.012 260);--rule:oklch(89% 0.008 260);
 --need:oklch(62% 0.16 55);--work:oklch(55% 0.15 245);--idle:oklch(60% 0.01 260);--focus:oklch(55% 0.15 245)}}
*{box-sizing:border-box}html,body{overflow-x:clip}
body{margin:0;background:var(--paper);color:var(--ink);font:400 15px/1.45 var(--font-body)}
header{display:flex;flex-wrap:wrap;align-items:center;gap:12px 28px;padding:18px 28px;border-bottom:1px solid var(--rule)}
.brand{font:500 15px var(--font-mono);letter-spacing:.02em}.brand span{color:var(--ink-3)}
.stats{display:flex;gap:2px;margin-left:auto}
.stat{background:var(--paper-2);padding:6px 14px;font:500 13px var(--font-mono);color:var(--ink-2);display:flex;gap:8px;align-items:baseline}
.stat b{font-size:19px;font-weight:500;color:var(--c)}
.stat:first-child{border-radius:6px 0 0 6px}.stat:last-child{border-radius:0 6px 6px 0}
.upd{font:13px var(--font-mono);color:var(--ink-3)}
main{padding:4px 28px 28px}
h2{font:500 12px var(--font-mono);letter-spacing:.12em;text-transform:uppercase;color:var(--c);margin:26px 0 6px;display:flex;gap:10px;align-items:center}
h2::after{content:"";flex:1;height:1px;background:var(--rule)}
.row{display:grid;grid-template-columns:20px 220px minmax(0,1fr) 180px 60px;gap:12px;align-items:baseline;padding:11px 10px;border-radius:6px;cursor:pointer}
.row:hover{background:var(--paper-2)}
.row.focused{background:var(--paper-2);box-shadow:inset 2px 0 var(--c)}
.dot{width:8px;height:8px;border-radius:50%;background:var(--c);align-self:center;box-shadow:0 0 0 3px color-mix(in oklch,var(--c) 22%,transparent)}
.n{font:500 14px var(--font-mono);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.t{font-weight:500;overflow-wrap:anywhere;min-width:0}
.tag{font:500 12px var(--font-mono);color:var(--c);border:1px solid color-mix(in oklch,var(--c) 45%,transparent);border-radius:4px;padding:1px 6px;margin-right:8px;white-space:nowrap}
.m{font:13px var(--font-mono);color:var(--ink-3);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.age{font:13px var(--font-mono);color:var(--ink-2);text-align:right}
.tg{background:none;border:0;border-radius:4px;color:var(--ink-3);font:13px var(--font-mono);padding:0 4px;margin-left:8px;cursor:pointer}
.tg:hover{color:var(--ink)}.tg:focus-visible{outline:2px solid var(--focus);outline-offset:2px}
pre{grid-column:2/-1;font:13px/1.5 var(--font-mono);color:var(--ink-2);background:var(--paper);border:1px solid var(--rule);border-radius:6px;
 padding:10px 12px;white-space:pre-wrap;overflow-wrap:anywhere;max-height:280px;overflow:auto;margin:8px 0 0;cursor:auto}
.r-need{--c:var(--need)}.r-work{--c:var(--work)}.r-idle{--c:var(--idle)}
@media (max-width:700px){header,main{padding-left:16px;padding-right:16px}.stats{margin-left:0}
 .row{grid-template-columns:20px minmax(0,1fr) 48px;padding:10px 6px}.n{grid-column:2}.t{grid-column:2/-1}.m{display:none}}
</style></head><body>
<header><div class="brand">herdr<span> / board</span></div><div class="stats" id="sum"></div><div class="upd" id="up"></div></header>
<main id="b"></main>
<script>
const SECS=[["need","needs you",["blocked","done"]],["work","working",["working"]],["idle","idle",null]];
const open=new Set();
const ago=s=>{const d=Date.now()/1000-s;return d<60?"now":d<3600?Math.floor(d/60)+"m":d<86400?Math.floor(d/3600)+"h":Math.floor(d/86400)+"d"};
const el=(t,c,txt)=>{const e=document.createElement(t);if(c)e.className=c;if(txt!=null)e.textContent=txt;return e};
async function load(){
  const agents=await (await fetch("/agents")).json();
  const b=document.getElementById("b"),sum=document.getElementById("sum");b.innerHTML="";sum.innerHTML="";
  for(const [key,label,keys] of SECS){
    const list=agents.filter(a=>keys?keys.includes(a.agent_status):!["blocked","done","working"].includes(a.agent_status))
      .sort((x,y)=>x.since-y.since);
    const s=el("div","stat r-"+key,label);s.prepend(el("b",null,list.length));sum.append(s);
    if(!list.length)continue;
    b.append(el("h2","r-"+key,`${label} ${list.length}`));
    for(const a of list){
      const r=el("div",`row r-${key}`+(a.focused?" focused":""));
      const t=el("div","t",a.terminal_title_stripped||a.pane_id);
      if(a.background)t.prepend(el("span","tag",`bg: ${a.background}`));
      if(a.agent_status==="done")t.prepend(el("span","tag","done"));
      const tg=el("button","tg",open.has(a.pane_id)?"▾ 出力":"▸ 出力");t.append(tg);
      r.append(el("span","dot"),el("span","n",(a.cwd||"").split("/").pop()||a.pane_id),t,
        el("span","m",`${a.agent} · ${a.pane_id}`),el("span","age",ago(a.since)));
      tg.onclick=e=>{e.stopPropagation();open.has(a.pane_id)?open.delete(a.pane_id):open.add(a.pane_id);load()};
      if(open.has(a.pane_id)){const p=el("pre");r.append(p);peek(a.pane_id,p);p.onclick=e=>e.stopPropagation()}
      r.onclick=()=>fetch("/focus?pane="+encodeURIComponent(a.pane_id),{method:"POST"}).then(load);
      b.append(r);
    }
  }
  const n=agents.filter(a=>["blocked","done"].includes(a.agent_status)).length;
  document.title=(n?`(${n}) `:"")+"herdr board";
  document.getElementById("up").textContent=new Date().toLocaleTimeString()+" 更新 · 行クリックでフォーカス";
}
async function peek(p,pre){pre.textContent=await (await fetch("/read?pane="+encodeURIComponent(p))).text()}
load();setInterval(load,3000);
</script></body></html>
