"""End-to-end demo of the Loss Prevention read tools (no MCP client needed).

    python scripts/demo_e2e.py     # after `pip install -e .`
"""

from __future__ import annotations

import queries
from tools import record_age_estimate, record_loss_event, store


def main() -> None:
    # The LP pipeline publishes loss scenarios and age estimates (the bridge seam).
    record_loss_event("hidden_items", "lane-1", "cam2", "high", "101", ref_id="demo-1",
                      description="Item concealed below basket")
    record_loss_event("product_switching", "lane-2", "cam5", "high", "201", ref_id="demo-2",
                      description="Label swap suspected")
    record_loss_event("product_switching", "lane-2", "cam5", "high", "201", ref_id="demo-2",
                      description="Duplicate redelivery")  # idempotent on ref_id
    record_age_estimate("18-25", "lane-1", "cam1", "301", "female", ref_id="demo-age-1")
    record_age_estimate("0-18", "lane-2", "cam1", "302", "male", ref_id="demo-age-2")

    print("Get_loss_history:", len(queries.loss_history(store)), "(idempotent = 2)")
    print("Get_loss_history(lane-2):", len(queries.loss_history(store, lane="lane-2")))
    print("Get_loss_event_count(product_switching):",
          queries.loss_event_count(store, scenario="product_switching"))
    print("Get_age_range_counts:", queries.age_range_counts(store))
    print("Get_lanes:", queries.lanes(store))
    print("\nOK - LP queries and service-owned SQLite store work end-to-end.")


if __name__ == "__main__":
    main()
