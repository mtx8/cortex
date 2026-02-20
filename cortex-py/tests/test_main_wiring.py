import pytest
from cortex.main import create_app_components


def test_create_components():
    components = create_app_components()
    assert "bus" in components
    assert "orchestrator" in components
    assert "autonomy" in components
    assert "pipeline" in components


def test_components_wired():
    components = create_app_components()
    orch = components["orchestrator"]
    assert orch.agent_count > 0


def test_edgar_and_financials_components():
    components = create_app_components()
    assert "edgar_client" in components
    assert "financials" in components
