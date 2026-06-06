# Ray 2.9 (py3.10) GPU image — required for KubeRay operator 1.1.x (its Serve
# REST API only exists in Ray >= 2.9; Ray 2.6 returns 404 on UpdateDeployments).
FROM rayproject/ray-ml:2.9.0-py310-gpu

# diffusers/transformers compatible with this base (torch 2.0.1, py3.10).
# Loads the Stable Diffusion v2 dreambooth model (askulkarni2/dogbooth).
RUN pip install --no-cache-dir \
    "transformers==4.38.2" \
    "diffusers==0.27.2" \
    "accelerate==0.27.2" \
    "huggingface_hub==0.20.3"

WORKDIR /serve_app

COPY dogbooth.py /serve_app/dogbooth.py
