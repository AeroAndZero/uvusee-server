"""Send an image edit to a running ComfyUI server and get the result back.

Uses ming_image_edit_workflow_api.json as the template and replaces its input
image, prompt and seed per call. Every failure raises MingError.

    from ming_client import edit, MingError
    png_bytes = edit(image_bytes, "Add a realistic housefly texture to it.")
"""

import json
import random
import uuid
from pathlib import Path

import requests
import websocket  # pip install websocket-client

COMFY = "127.0.0.1:8188"
WORKFLOW = json.loads("ming_image_edit_workflow_api.json").read_text()
TIMEOUT = 600  # seconds for one edit

# Node ids in the workflow file
IMAGE_NODE, PROMPT_NODE, SEED_NODE, SIZE_NODE, OUTPUT_NODE = "32", "34", "10", "15", "30"


class MingError(Exception):
    pass


def edit(image: bytes, prompt: str, seed: int | None = None, megapixels: float = 1.0,
         host: str = COMFY) -> bytes:
    """Run the workflow on `image` and return the result as PNG bytes.
    megapixels: 1.0, 2.25 or 4.0 for 1024, 1536 or 2048 output."""
    http, client_id = f"http://{host}", uuid.uuid4().hex
    try:
        # Upload under a unique name so concurrent requests don't overwrite each other
        r = requests.post(f"{http}/upload/image", files={"image": (f"{client_id}.png", image)}, timeout=30)
        r.raise_for_status()

        wf = json.loads(json.dumps(WORKFLOW))
        wf[IMAGE_NODE]["inputs"]["image"] = r.json()["name"]
        wf[PROMPT_NODE]["inputs"]["value"] = prompt
        wf[SEED_NODE]["inputs"]["seed"] = random.randrange(2**63) if seed is None else seed
        wf[SIZE_NODE]["inputs"]["megapixels"] = megapixels

        # Listen before queueing so no event is missed
        ws = websocket.create_connection(f"ws://{host}/ws?clientId={client_id}", timeout=TIMEOUT)
        try:
            r = requests.post(f"{http}/prompt", json={"prompt": wf, "client_id": client_id}, timeout=30)
            if r.status_code != 200:
                raise MingError(f"workflow rejected: {r.text[:1000]}")
            prompt_id = r.json()["prompt_id"]

            while True:
                msg = ws.recv()
                if isinstance(msg, bytes):  # preview frames
                    continue
                msg = json.loads(msg)
                data = msg.get("data", {})
                if data.get("prompt_id") != prompt_id:
                    continue
                if msg["type"] == "execution_error":
                    raise MingError(f"{data.get('node_type')} failed: {data.get('exception_message', '').strip()}")
                if msg["type"] == "executing" and data.get("node") is None:  # finished, history written
                    break
        finally:
            ws.close()

        images = requests.get(f"{http}/history/{prompt_id}", timeout=30).json()[prompt_id]["outputs"][OUTPUT_NODE]["images"]
        r = requests.get(f"{http}/view", params=images[0], timeout=30)
        r.raise_for_status()
        return r.content

    except MingError:
        raise
    except (requests.RequestException, websocket.WebSocketException, OSError, KeyError, IndexError) as e:
        raise MingError(f"{type(e).__name__}: {e}") from e