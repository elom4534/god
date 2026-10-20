from pydantic import BaseModel, Field
from typing import Optional, List, Any
from datetime import datetime

class SelectionSchema(BaseModel):
    selection_id: str
    name: str
    tags: List[str] = []
    odds_internal: Optional[float] = None  # internal only

class MarketSchema(BaseModel):
    market_id: str
    market_type: str
    name: str
    period: str = "FT"
    line: Optional[float] = None
    selections: List[SelectionSchema]

class EventSchema(BaseModel):
    event_id: str
    sport: str = "football"
    league: str
    start_time: datetime
    home: str
    away: str
    is_virtual: bool = False
    provider: Optional[str] = None
    markets: List[MarketSchema] = []

class EventsIngestRequest(BaseModel):
    provider: Optional[str] = "1xBet"
    is_virtual: bool = False
    raw_events: List[Any]
    as_of: Optional[datetime] = None

class EventsIngestResponse(BaseModel):
    normalized: List[EventSchema]
    rejected: List[dict]
    model_version: str
    as_of: datetime
