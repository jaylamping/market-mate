# Incubator Control Room Prototype

Three variants of the Principal control room, switchable via `?variant=`, on the disposable `/prototype/incubator-control-room/` route.

This is a read-only interaction prototype. It uses simulated state, performs no persistence or authorization, and intentionally lives outside the production architecture.

## Run

From the repository root:

```bash
python3 -m http.server 4173
```

Open [http://localhost:4173/prototype/incubator-control-room/?variant=A](http://localhost:4173/prototype/incubator-control-room/?variant=A).

- `A` — Floor Map: topology and swarm-first
- `B` — Opportunity Tape: work-market and artifact-first
- `C` — Principal Lens: decisions and exceptions-first

Use the floating arrows or keyboard left/right arrows to switch. Raw agent messages, tool traces, and token streams are intentionally absent; the prototype shows admitted artifacts, economic state, immutable controls, and exact Principal decisions.
