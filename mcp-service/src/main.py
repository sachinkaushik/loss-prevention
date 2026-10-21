"""Start the Loss Prevention FastMCP server.

The durable log is populated by `scripts/import_jsonl.py` (non-VLM pipeline
JSONL output) and `scripts/seed_demo.py`. A RabbitMQ consumer (VLM workload
only) can be added later.
"""

from __future__ import annotations

from config import get_settings
from tools import mcp


def main() -> None:
    s = get_settings()
    if s.transport in {"http", "streamable-http"}:
        mcp.run(transport="http", host=s.host, port=s.port)
    else:
        mcp.run(transport="stdio")


if __name__ == "__main__":
    main()
