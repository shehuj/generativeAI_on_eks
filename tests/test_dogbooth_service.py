"""Tests for the dogbooth Ray Serve service (src/service/dogbooth.py)."""

import pytest


def test_validate_prompt_accepts_non_empty(dogbooth_service):
    # Returns None and does not raise for a valid prompt.
    assert dogbooth_service.validate_prompt("a photo of a [v]dog") is None


def test_validate_prompt_rejects_empty(dogbooth_service):
    with pytest.raises(AssertionError, match="prompt parameter cannot be empty"):
        dogbooth_service.validate_prompt("")


def test_validate_prompt_accepts_whitespace_only(dogbooth_service):
    # Current contract only checks length, so a single space is considered valid.
    assert dogbooth_service.validate_prompt(" ") is None


def test_service_defines_serve_entrypoint(dogbooth_service):
    # The module wires an `entrypoint` for `serveConfig.importPath: dogbooth:entrypoint`.
    assert hasattr(dogbooth_service, "entrypoint")
    assert dogbooth_service.entrypoint is not None


def test_service_defines_deployment_classes(dogbooth_service):
    assert hasattr(dogbooth_service, "APIIngress")
    assert hasattr(dogbooth_service, "StableDiffusionV2")
