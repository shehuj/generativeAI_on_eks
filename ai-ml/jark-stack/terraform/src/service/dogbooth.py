from io import BytesIO
from fastapi import FastAPI
from fastapi.responses import Response
import torch
import os
from ray import serve


app = FastAPI()


def validate_prompt(prompt: str) -> None:
    """Validate a generation prompt.

    Raises AssertionError when the prompt is empty. Extracted as a pure helper
    so the contract can be unit tested without loading the model.
    """
    assert len(prompt), "prompt parameter cannot be empty"


# route_prefix is set at the application level (serveConfigV2), not on the
# deployment — Ray Serve >= 2.9 removed route_prefix from @serve.deployment.
@serve.deployment(num_replicas=1)
@serve.ingress(app)
class APIIngress:
    def __init__(self, diffusion_model_handle) -> None:
        self.handle = diffusion_model_handle

    @app.get(
        "/imagine",
        responses={200: {"content": {"image/png": {}}}},
        response_class=Response,
    )
    async def generate(self, prompt: str, img_size: int = 768):
        validate_prompt(prompt)

        image_ref = await self.handle.generate.remote(prompt, img_size=img_size)
        image = await image_ref
        file_stream = BytesIO()
        image.save(file_stream, "PNG")
        return Response(content=file_stream.getvalue(), media_type="image/png")


@serve.deployment(
    ray_actor_options={"num_gpus": 1},
    autoscaling_config={"min_replicas": 1, "max_replicas": 2},
)
class StableDiffusionV2:
    def __init__(self):
        from diffusers import EulerDiscreteScheduler, StableDiffusionPipeline

        model_id = os.getenv('MODEL_ID')

        scheduler = EulerDiscreteScheduler.from_pretrained(
            model_id, subfolder="scheduler"
        )
        self.pipe = StableDiffusionPipeline.from_pretrained(
            model_id, scheduler=scheduler
        )
        self.pipe = self.pipe.to("cuda")

    def generate(self, prompt: str, img_size: int = 768):
        validate_prompt(prompt)

        image = self.pipe(prompt, height=img_size, width=img_size).images[0]
        return image


entrypoint = APIIngress.bind(StableDiffusionV2.bind())
