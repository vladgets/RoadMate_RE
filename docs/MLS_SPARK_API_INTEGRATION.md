# MLS Data Access via Spark API (FlexMLS)

## Overview

The brokerage uses **FlexMLS** (`mo.flexmls.com`), which is built by FBS (Flexible Business Solutions). FBS also operates the **Spark API** — the official, first-party developer API for all FlexMLS-powered MLSs. This is the recommended path for programmatic MLS data access.

## Relationship: FBS / FlexMLS / Spark API

- **FBS** builds and operates both FlexMLS and Spark API
- Spark API is what FBS's own FlexMLS mobile apps use internally — it is not a third-party bolt-on
- Spark API implements the **RESO Web API standard** (industry-wide standard replacing legacy RETS)
- Production endpoint: `https://sparkapi.com/`
- RESO/OData endpoint: `https://replication.sparkapi.com/Version/3/Reso/OData/`

## How to Get Access

1. **Register for free** at `sparkplatform.com` — takes up to 3 business days for activation
2. After activation, log in to the **Spark Datamart** and find your MLS's data plan (IDX, VOW, or Private)
3. Accept the MLS's terms, specify intended use, and submit
4. **MLS admin reviews and approves** → production API credentials sent via email
5. Contact `inquiry@sparkplatform.com` if your MLS has no published plan in the Datamart

**Cost: $50/month per MLS** (multiple API keys for the same MLS count as one charge)

## Available Data

- **Listings** — address, price, beds/baths, status, type, square footage, year built, timestamps
- **Photos** — multiple pre-resized versions (Thumb, 300, 640, 800, 1024, 1280, 1600, 2048px)
- **Open Houses**
- **Documents and Disclosures**
- **Virtual Tours and Videos**
- **Agent / Member info**
- **Office info**
- **Market Statistics** — absorption rate, inventory, average/median price, DOM, sale-to-list ratio, volume
- **Contacts** (agent CRM) — saved searches, favorites, listing notes, portal activity

## Access Roles

| Role | Description |
|------|-------------|
| IDX | Publicly displayable listings (most common) |
| VOW | Sold data + additional fields; end-users must log in |
| Private (Broker Back Office) | Full MLS access including agent-only fields and private remarks |

## Authentication

### Option A: Bearer Token (simplest, single-user)
A non-expiring token tied to a specific FlexMLS user account.

```
GET https://sparkapi.com/v1/listings
Authorization: Bearer <access_token>
```

### Option B: OpenID Connect / OAuth 2.0 (multi-user apps)
Standard OAuth 2.0 flow for per-agent authentication.

- Authorization URL: `https://sparkplatform.com/openid/authorize`
- Token URL: `https://sparkplatform.com/openid/token`
- Token lifetime: 24 hours (refresh token provided)

## Key API Endpoints

```
GET /v1/listings                    # All listings (with filters)
GET /v1/listings/<Id>               # Single listing
GET /v1/listings/nearby             # Listings by GPS coordinate
GET /v1/my/listings                 # Current agent's listings
GET /v1/office/listings             # Office listings

GET /v1/marketstatistics/price      # Price trends
GET /v1/marketstatistics/inventory  # Inventory counts
GET /v1/marketstatistics/dom        # Days on market
GET /v1/marketstatistics/absorption # Absorption rate

# RESO/OData
GET /Version/3/Reso/OData/Property
GET /Version/3/Reso/OData/Property('<Id>')?$expand=Media,OpenHouse
GET /Version/3/Reso/OData/$metadata
```

## Example Request

```
GET https://sparkapi.com/v1/listings?_expand=Photos,OpenHouses&_limit=10
Authorization: Bearer <access_token>
```

## Rate Limits

| Key Type | Limit |
|----------|-------|
| IDX | 1,500 requests per 5-minute rolling window |
| VOW / Private | 4,000 requests per 5-minute rolling window |

Returns HTTP 429 when exceeded.

## Planned RoadMate Voice Commands

Once integrated, the assistant will support:
- "Show me active listings in Hoboken under $700k"
- "What's the status of 123 Main Street?"
- "Find 3-bed homes near my location"
- "What are the newest listings this week?"
- "How's the market in Jersey City — average days on market?"
- "Pull up the photos for MLS# 12345"

## Next Steps

1. Register at `sparkplatform.com`
2. Find and enroll in your MLS's IDX data plan in the Spark Datamart
3. Once credentials are received, add `SPARK_API_KEY` to the server environment
4. Implement `server/spark.js` proxy and `lib/services/spark_client.dart`

## Resources

- Developer docs: `sparkplatform.com/docs`
- Datamart (requires login): `sparkplatform.com/ticket`
- Support: `inquiry@sparkplatform.com`
