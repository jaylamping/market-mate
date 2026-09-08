# Market Mate

Local Research workspace for bounded strategy research, observed-data diagnostics, and supervisory views. The broader domain model describes later stages; the current application grants zero order authority.

- Agents and new contributors: start with [AGENTS.md](AGENTS.md).
- System map and implementation boundaries: [architecture](docs/architecture.md).
- Local prerequisites and reproducible checks: [verification](docs/agents/verification.md).
- Domain language: [CONTEXT.md](CONTEXT.md). UI conventions: [DESIGN.md](DESIGN.md).
- Decision rationale: [ADRs](docs/adr/README.md). Work lives in [GitHub Issues](https://github.com/jaylamping/market-mate/issues).

Inspect an existing checkout without changing runtime state:

```sh
python3 scripts/doctor.py --runtime
```

Install frontend dependencies with `npm --prefix frontend ci` when needed, then run `bash scripts/verify.sh`. Read the verification guide before starting containers or running acceptance scripts; a configured worker can dispatch real provider requests. Configure providers with `scripts/setup_openrouter.py`, `scripts/setup_zai.py`, `scripts/setup_opencode.py`, and `scripts/setup_cheaper_inference.py`.
