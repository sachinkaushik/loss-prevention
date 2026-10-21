"""Typed structures returned by the Loss Prevention tools (structured output)."""

from __future__ import annotations

from typing import TypedDict


class LossEvent(TypedDict):
    """One self-checkout loss scenario, flattened for the agent."""

    ref_id: str
    ts_ms: int
    timestamp: str
    event_type: str
    scenario: str
    lane: str
    camera_id: str
    severity: str
    tracking_id: str
    frame: str
    description: str


class AgeEstimate(TypedDict):
    """One age-range classification, flattened for the agent."""

    ref_id: str
    ts_ms: int
    timestamp: str
    event_type: str
    age_range: str
    lane: str
    camera_id: str
    tracking_id: str
    gender: str
    frame: str


class AgeRangeCount(TypedDict):
    """Count of age estimates for one age range over the queried period."""

    age_range: str
    count: int
