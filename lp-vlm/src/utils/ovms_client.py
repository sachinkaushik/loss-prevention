import base64
from io import BytesIO

import numpy as np
import requests
from PIL import Image


class OVMSVLMClient:
    def __init__(self, endpoint, model_name, timeout=120, max_new_tokens=512, temperature=0.0):
        self.endpoint = f"{endpoint.rstrip('/')}/v3/chat/completions"
        self.model_name = model_name
        self.timeout = timeout
        self.max_new_tokens = max_new_tokens
        self.temperature = temperature

    def _encode_image(self, image):
        pil_img = Image.fromarray(image.astype("uint8"))
        buffer = BytesIO()
        pil_img.save(buffer, format="JPEG", quality=82, optimize=True)
        img_b64 = base64.b64encode(buffer.getvalue()).decode("utf-8")
        return f"data:image/jpeg;base64,{img_b64}"

    def generate(self, prompt, images=None):
        images = images or []
        content = [{"type": "text", "text": prompt}]

        for image in images:
            content.append(
                {
                    "type": "image_url",
                    "image_url": {"url": self._encode_image(np.asarray(image))},
                }
            )

        request_data = {
            "model": self.model_name,
            "messages": [{"role": "user", "content": content}],
            "max_completion_tokens": self.max_new_tokens,
            "temperature": self.temperature,
        }

        response = requests.post(
            self.endpoint,
            headers={"Content-Type": "application/json"},
            json=request_data,
            timeout=self.timeout,
        )
        response.raise_for_status()

        payload = response.json()
        text = payload.get("choices", [{}])[0].get("message", {}).get("content", "")

        class GenerationResult:
            def __init__(self, generated_text):
                self.texts = [generated_text]

        return GenerationResult(text)