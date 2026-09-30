"""News-event taxonomy and source-reliability tiers."""
from __future__ import annotations

from enum import Enum


class EventType(str, Enum):
    LISTING = "LISTING"
    DELISTING = "DELISTING"
    PARTNERSHIP = "PARTNERSHIP"
    PROTOCOL_UPGRADE = "PROTOCOL_UPGRADE"
    TOKEN_UNLOCK = "TOKEN_UNLOCK"
    BURN = "BURN"
    SUPPLY_CHANGE = "SUPPLY_CHANGE"
    GOVERNANCE = "GOVERNANCE"
    EXPLOIT = "EXPLOIT"
    REGULATORY = "REGULATORY"
    ETF = "ETF"
    INSTITUTIONAL = "INSTITUTIONAL"
    MACRO = "MACRO"
    WHALE_MOVEMENT = "WHALE_MOVEMENT"
    CELEBRITY_MENTION = "CELEBRITY_MENTION"
    CULTURAL_EVENT = "CULTURAL_EVENT"
    PROJECT_ANNOUNCEMENT = "PROJECT_ANNOUNCEMENT"
    CHAIN_ANNOUNCEMENT = "CHAIN_ANNOUNCEMENT"
    OTHER = "OTHER"


class SourceTier(int, Enum):
    PRIMARY = 1       # exchange announcement pages, official project/chain accounts & blogs, regulators
    ESTABLISHED = 2   # established newsrooms with editorial standards and corrections
    AGGREGATOR = 3    # aggregators, crypto-native outlets that republish, data dashboards
    UNVERIFIED = 4    # arbitrary social posts, Telegram, anonymous accounts


# Prior credibility per tier; calibrate against observed accuracy (docs/research/06).
TIER_CREDIBILITY = {1: 0.95, 2: 0.8, 3: 0.55, 4: 0.2}

# Expected direction of first-order price impact for the token named in the event.
EXPECTED_DIRECTION = {
    EventType.LISTING: 1, EventType.DELISTING: -1, EventType.PARTNERSHIP: 1, EventType.BURN: 1,
    EventType.TOKEN_UNLOCK: -1, EventType.EXPLOIT: -1, EventType.ETF: 1, EventType.INSTITUTIONAL: 1,
    EventType.CELEBRITY_MENTION: 1, EventType.WHALE_MOVEMENT: 0, EventType.REGULATORY: 0,
    EventType.MACRO: 0, EventType.GOVERNANCE: 0, EventType.PROTOCOL_UPGRADE: 1,
    EventType.SUPPLY_CHANGE: 0, EventType.CULTURAL_EVENT: 1, EventType.PROJECT_ANNOUNCEMENT: 1,
    EventType.CHAIN_ANNOUNCEMENT: 0, EventType.OTHER: 0,
}

# Keyword rules are a transparent baseline classifier, to be replaced by a
# validated model only if it beats these out of sample.
KEYWORDS: list[tuple[EventType, tuple[str, ...]]] = [
    (EventType.EXPLOIT, ("exploit", "hack", "drained", "attack", "vulnerability", "stolen")),
    (EventType.DELISTING, ("delist", "will remove", "suspend trading")),
    (EventType.LISTING, ("will list", "lists ", "listing", "now available for trading", "perpetual launch")),
    (EventType.TOKEN_UNLOCK, ("unlock", "vesting")),
    (EventType.BURN, ("burn", "burned", "burnt")),
    (EventType.ETF, ("etf",)),
    (EventType.REGULATORY, ("sec ", "cftc", "regulator", "lawsuit", "enforcement", "ban ")),
    (EventType.GOVERNANCE, ("proposal", "governance", "vote")),
    (EventType.PARTNERSHIP, ("partner", "integration", "collaborat")),
    (EventType.PROTOCOL_UPGRADE, ("upgrade", "mainnet", "hard fork", "v2 launch")),
    (EventType.MACRO, ("fed ", "cpi", "rate cut", "rate hike", "inflation", "payrolls")),
    (EventType.INSTITUTIONAL, ("treasury", "fund buys", "institutional")),
    (EventType.WHALE_MOVEMENT, ("whale", "transferred", "moved to exchange")),
]


def classify_headline(headline: str) -> EventType:
    h = f" {headline.lower()} "
    for et, words in KEYWORDS:
        if any(w in h for w in words):
            return et
    return EventType.OTHER
