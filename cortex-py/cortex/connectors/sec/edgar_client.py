"""SEC EDGAR API client for company filings and data.

EDGAR is free — no API key required. Rate limit: 10 req/s (be respectful).
User-Agent header required by SEC: include company name and email.
"""

import structlog
import httpx

log = structlog.get_logger()

# SEC requires a descriptive User-Agent
USER_AGENT = "Cortex Trading Platform admin@cortex.local"

# CIK lookup cache
_cik_cache: dict[str, str] = {}


class EDGARClient:
    """Async client for SEC EDGAR API."""

    def __init__(self):
        self._client = httpx.AsyncClient(
            timeout=15.0,
            headers={"User-Agent": USER_AGENT, "Accept": "application/json"},
        )

    async def close(self):
        await self._client.aclose()

    async def get_cik(self, ticker: str) -> str | None:
        """Look up CIK number for a ticker symbol."""
        ticker = ticker.upper()
        if ticker in _cik_cache:
            return _cik_cache[ticker]

        try:
            resp = await self._client.get(
                "https://www.sec.gov/files/company_tickers.json"
            )
            if resp.status_code == 200:
                data = resp.json()
                for entry in data.values():
                    if entry.get("ticker", "").upper() == ticker:
                        cik = str(entry["cik_str"]).zfill(10)
                        _cik_cache[ticker] = cik
                        return cik
        except Exception as e:
            log.error("edgar.cik_lookup_failed", ticker=ticker, error=str(e))

        return None

    async def get_filings(
        self,
        ticker: str,
        filing_types: list[str] | None = None,
        limit: int = 20,
    ) -> list[dict]:
        """Get recent SEC filings for a ticker.

        Args:
            ticker: Stock ticker symbol
            filing_types: Filter by form type (e.g., ["10-K", "10-Q", "8-K", "4"])
            limit: Max results

        Returns:
            List of filing dicts with keys: id, type, filed_date, description, url
        """
        cik = await self.get_cik(ticker)
        if not cik:
            log.warning("edgar.no_cik", ticker=ticker)
            return []

        try:
            url = f"https://data.sec.gov/submissions/CIK{cik}.json"
            resp = await self._client.get(url)
            if resp.status_code != 200:
                return []

            data = resp.json()
            recent = data.get("filings", {}).get("recent", {})

            forms = recent.get("form", [])
            dates = recent.get("filingDate", [])
            descriptions = recent.get("primaryDocDescription", [])
            accessions = recent.get("accessionNumber", [])
            primary_docs = recent.get("primaryDocument", [])

            filings = []
            for i in range(min(len(forms), 100)):
                form_type = forms[i] if i < len(forms) else ""

                # Filter by type if specified
                if filing_types and form_type not in filing_types:
                    continue

                accession = accessions[i].replace("-", "") if i < len(accessions) else ""
                primary_doc = primary_docs[i] if i < len(primary_docs) else ""

                filing = {
                    "id": accession,
                    "type": form_type,
                    "filed_date": dates[i] if i < len(dates) else "",
                    "description": descriptions[i] if i < len(descriptions) else form_type,
                    "url": (
                        f"https://www.sec.gov/Archives/edgar/data/"
                        f"{cik.lstrip('0')}/{accession}/{primary_doc}"
                        if accession and primary_doc
                        else ""
                    ),
                }
                filings.append(filing)

                if len(filings) >= limit:
                    break

            log.info("edgar.filings_fetched", ticker=ticker, count=len(filings))
            return filings

        except Exception as e:
            log.error("edgar.filings_error", ticker=ticker, error=str(e))
            return []

    async def get_company_info(self, ticker: str) -> dict | None:
        """Get basic company info from EDGAR."""
        cik = await self.get_cik(ticker)
        if not cik:
            return None

        try:
            url = f"https://data.sec.gov/submissions/CIK{cik}.json"
            resp = await self._client.get(url)
            if resp.status_code != 200:
                return None

            data = resp.json()
            return {
                "name": data.get("name", ""),
                "cik": cik,
                "sic": data.get("sic", ""),
                "sic_description": data.get("sicDescription", ""),
                "ticker": ticker.upper(),
                "exchange": (
                    data.get("exchanges", [""])[0] if data.get("exchanges") else ""
                ),
                "state": data.get("stateOfIncorporation", ""),
                "fiscal_year_end": data.get("fiscalYearEnd", ""),
            }
        except Exception as e:
            log.error("edgar.company_info_error", ticker=ticker, error=str(e))
            return None
