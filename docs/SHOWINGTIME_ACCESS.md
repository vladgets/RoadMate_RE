# ShowingTime API Access Research

## Overview

ShowingTime is the dominant real estate showing management platform in the US. It was acquired by Zillow Group in 2021 for $500M and rebranded as part of **ShowingTime+**. This document summarizes the available API access options and their limitations.

## Current Status: No Public Scheduling API

ShowingTime does **not** offer a public developer API for checking availability, scheduling, or canceling showings. All appointment operations are locked behind their consumer app and MLS-integrated web UI.

Zillow's acquisition has made the platform more closed over time, with industry concerns about competitive data access.

## What Does Exist

### Bridge API (ShowingTime+ / Bridge Interactive)
A **listing data API** only — not for showings.

- Provides MLS listing data normalized to the RESO Data Dictionary standard
- RESO Web API / OData format
- Base URL: `https://api.bridgedataoutput.com/api/v2/OData/{dataset_code}/{Resource}`
- Auth: Bearer token (MLS-issued)
- **Does not** support checking available showing times, scheduling, or cancellation
- Access requires your MLS to already be a Bridge customer; you apply through your MLS

### API Nation Connector
ShowingTime is listed on API Nation (`my.apination.com/apps/showing_time`) but no scheduling triggers or actions are publicly documented. Authentication is noted as non-OAuth (basic API key), but no further public documentation exists.

## Access Path (If It Becomes Available)

Any future integration would require:
1. A direct business relationship with ShowingTime/Zillow Group
2. MLS membership or formal vendor/partner agreement
3. Likely similar tier to their lockbox partners (SentriLock, Supra, igloohome)

Contact: `feedback@showingtime.com` or `(800) 379-0057`

## Alternative Scheduling Platforms With APIs

If showing scheduling via API is needed, these platforms offer documented access:

| Platform | Type | API Access | Notes |
|----------|------|------------|-------|
| **Calendly** | General scheduling | Public REST API, OAuth 2.0 | Not real-estate specific but well-documented |
| **Acuity Scheduling** | General scheduling | Public API | Supports availability checks + booking |
| **Showdigs** | AI showing platform | Contact required | Targets property managers |
| **Instashowing** | RE showing management | No confirmed public API | Smaller, more approachable |

## Recommendation

**Put on hold** — ShowingTime integration is not feasible without a formal partnership with Zillow Group. Revisit if:
- ShowingTime publishes a developer program
- A direct partnership with Zillow/ShowingTime becomes possible
- A viable alternative showing platform with API access is identified

In the meantime, showing-related coordination can be handled through Follow Up Boss tasks and calendar events already integrated in RoadMate.

## Resources

- ShowingTime product page: `showingtime.com`
- Bridge API (listing data only): `bridgeinteractive.com/developers/bridge-api/`
- Bridge API docs: `bridgedataoutput.com/docs/platform/`
- API Nation listing: `my.apination.com/apps/showing_time`
