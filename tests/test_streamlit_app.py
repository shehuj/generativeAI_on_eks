"""Tests for the dogbooth Streamlit app (src/app/streamlit.py)."""

from urllib.parse import parse_qs, urlparse


def test_build_image_url_appends_query(streamlit_app):
    url = streamlit_app.build_image_url("http://dogbooth.svc/imagine", "a [v]dog")
    parsed = urlparse(url)
    assert parsed.scheme == "http"
    assert parsed.path == "/imagine"
    assert parse_qs(parsed.query) == {"prompt": ["a [v]dog"]}


def test_build_image_url_percent_encodes_special_chars(streamlit_app):
    url = streamlit_app.build_image_url("http://host/imagine", "a photo of a [v]dog")
    # Raw spaces / brackets must not leak into the URL.
    assert " " not in url
    assert "[" not in url and "]" not in url
    # ...but decode back to the original prompt.
    assert parse_qs(urlparse(url).query)["prompt"] == ["a photo of a [v]dog"]


def test_build_image_url_handles_empty_base_url(streamlit_app):
    # base_url defaults to "" in the app until the hostname is set at build time.
    url = streamlit_app.build_image_url("", "sunset")
    assert url == "?prompt=sunset"


def test_build_image_url_is_stable_for_same_input(streamlit_app):
    a = streamlit_app.build_image_url("http://h", "x")
    b = streamlit_app.build_image_url("http://h", "x")
    assert a == b


def test_module_exposes_main_entrypoint(streamlit_app):
    # UI is guarded behind main()/__main__ so importing the module is side-effect free.
    assert callable(streamlit_app.main)
