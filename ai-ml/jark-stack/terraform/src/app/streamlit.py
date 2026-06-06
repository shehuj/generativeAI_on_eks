import streamlit as st
import requests
from urllib.parse import urlencode
from PIL import Image
import tempfile


### Ray Serve dogbooth endpoint (in-cluster). The Streamlit pod calls this
### server-side; KubeRay exposes the serve app on <rayservice>-serve-svc:8000.
base_url = "http://dogbooth-serve-svc.dogbooth.svc.cluster.local:8000/imagine"


def build_image_url(base_url: str, prompt: str) -> str:
    """Build the image-generation request URL for a given prompt.

    Kept as a small pure function so it can be unit tested without a running
    Streamlit server.
    """
    return f"{base_url}?{urlencode({'prompt': prompt})}"


def main() -> None:
    st.title("Welcome to dogbooth! :dog:")
    st.header("_a place to create images of [v]dog  in beautiful scenes._")

    prompt = st.chat_input("a photo of a [v]dog ...")
    if prompt:
        image_url = build_image_url(base_url, prompt)

        with st.spinner("Wait for it..."):
            response = requests.get(image_url, timeout=180)

            if response.status_code == 200:
                with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as f:
                    f.write(response.content)
                st.image(Image.open(f.name), caption=prompt)
                st.balloons()
            else:
                st.error(f"Failed to download image. Status code: {response.status_code}")


if __name__ == "__main__":
    main()
