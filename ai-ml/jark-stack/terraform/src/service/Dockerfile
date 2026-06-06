FROM rayproject/ray-ml:2.6.0-gpu

# Pin to released versions compatible with this base image's Python/torch.
# Installing transformers from git main pulls bleeding-edge deps (e.g.
# huggingface-hub>=1.5.0) that are not available for the base image's Python,
# which breaks the build. These pins match the Stable Diffusion v2 era used by
# the dogbooth model.
RUN pip install --no-cache-dir \
    "transformers==4.30.2" \
    "diffusers==0.19.3" \
    "huggingface_hub==0.16.4" \
    "accelerate==0.21.0"

WORKDIR /serve_app

COPY dogbooth.py /serve_app/dogbooth.py
