"""Request bodies (Pydantic v2)."""
from __future__ import annotations

from typing import Dict, List, Optional

from pydantic import BaseModel, Field, field_validator

from .db import NUMBER_ORDERS


class PairRequest(BaseModel):
    pairing_code: str = Field(min_length=1, max_length=20)
    device_name: str = Field(default="Phone", max_length=60)


class ParentLogin(BaseModel):
    pin: str = Field(min_length=1, max_length=20)


class PaperCount(BaseModel):
    name: str
    count: int = Field(ge=0)


class RunEvent(BaseModel):
    address_id: int
    t: int = Field(ge=0, description="Seconds since the run started")


class RunUpload(BaseModel):
    client_run_id: str = Field(min_length=8, max_length=64)
    kid_id: Optional[int] = None
    route_id: Optional[int] = None
    date: str = Field(pattern=r"^\d{4}-\d{2}-\d{2}$")
    weekday: int = Field(ge=1, le=7)
    started_at: str
    finished_at: str
    duration_seconds: int = Field(ge=0)
    stops_total: int = Field(ge=0)
    stops_done: int = Field(ge=0)
    papers: Dict[str, PaperCount] = Field(default_factory=dict)
    events: List[RunEvent] = Field(default_factory=list)


class KidIn(BaseModel):
    name: str = Field(min_length=1, max_length=40)
    emoji: str = Field(default="", max_length=8)
    color: str = Field(default="#4F46E5", pattern=r"^#[0-9A-Fa-f]{6}$")
    default_route_id: Optional[int] = None


def _clean_days(days: List[int]) -> List[int]:
    return sorted({int(d) for d in days if 1 <= int(d) <= 7})


class ProductIn(BaseModel):
    name: str = Field(min_length=1, max_length=40)
    short_code: str = Field(min_length=1, max_length=3)
    color: str = Field(pattern=r"^#[0-9A-Fa-f]{6}$")
    days: List[int] = Field(default_factory=list)
    kind: str = Field(default="paper", pattern=r"^(paper|insert)$")

    @field_validator("days")
    @classmethod
    def _valid_days(cls, days: List[int]) -> List[int]:
        return _clean_days(days)


class RouteIn(BaseModel):
    name: str = Field(min_length=1, max_length=60)


def _check_order(value: Optional[str]) -> Optional[str]:
    if value is not None and value not in NUMBER_ORDERS:
        raise ValueError("number_order must be one of: " + ", ".join(NUMBER_ORDERS))
    return value


class StreetIn(BaseModel):
    name: str = Field(min_length=1, max_length=80)
    number_order: str = "asc"

    @field_validator("number_order")
    @classmethod
    def _valid_order(cls, value: str) -> str:
        return _check_order(value) or "asc"


class StreetUpdate(BaseModel):
    name: Optional[str] = Field(default=None, min_length=1, max_length=80)
    number_order: Optional[str] = None

    @field_validator("number_order")
    @classmethod
    def _valid_order(cls, value: Optional[str]) -> Optional[str]:
        return _check_order(value)


class AddressProductIn(BaseModel):
    product_id: int
    days: Optional[List[int]] = None  # None = product default

    @field_validator("days")
    @classmethod
    def _valid_days(cls, days: Optional[List[int]]) -> Optional[List[int]]:
        return None if days is None else _clean_days(days)


class AddressIn(BaseModel):
    number: int = Field(ge=0, le=99999)
    suffix: str = Field(default="", max_length=10)
    note: str = Field(default="", max_length=200)
    products: List[AddressProductIn] = Field(default_factory=list)


class AddressUpdate(BaseModel):
    number: Optional[int] = Field(default=None, ge=0, le=99999)
    suffix: Optional[str] = Field(default=None, max_length=10)
    note: Optional[str] = Field(default=None, max_length=200)
    products: Optional[List[AddressProductIn]] = None  # replaces all assignments when given


class BulkAddresses(BaseModel):
    start: int = Field(ge=0, le=99999)
    end: int = Field(ge=0, le=99999)
    parity: str = Field(default="all", pattern=r"^(all|odd|even)$")
    products: List[AddressProductIn] = Field(default_factory=list)


class AssignmentUpdate(BaseModel):
    address_ids: List[int]
    product_id: int
    assigned: bool = True
    days: Optional[List[int]] = None

    @field_validator("days")
    @classmethod
    def _valid_days(cls, days: Optional[List[int]]) -> Optional[List[int]]:
        return None if days is None else _clean_days(days)


class OrderIn(BaseModel):
    ids: List[int]


class SettingsIn(BaseModel):
    family_name: Optional[str] = Field(default=None, min_length=1, max_length=60)
    new_pin: Optional[str] = Field(default=None, min_length=4, max_length=12)
    pairing_code: Optional[str] = Field(default=None, min_length=4, max_length=20)
