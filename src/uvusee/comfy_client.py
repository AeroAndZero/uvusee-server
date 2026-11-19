"""Run any ComfyUI API-format workflow, setting inputs by node title.

Name the nodes you want to fill in ComfyUI (right-click > Title), export with
Workflow > Export (API), then:

    from comfy_client import Workflow, ComfyError

    flux = Workflow("workflows/flux2_klein_9b_workflow_api.json",
                    require=("UVUSEE_IMAGE", "UVUSEE_PROMPT"), output="UVUSEE_OUTPUT",
                    seed_node="UVUSEE_KSAMPLER")
    images = flux.run({"UVUSEE_IMAGE": png_bytes, "UVUSEE_PROMPT": "Add a housefly texture"})

How a value is applied to the node with that title:
    bytes        uploaded to ComfyUI, then set as the node's "image" input (LoadImage)
    str          set as the node's text input ("text", "value", "prompt" or "string")
    "TITLE.field" set exactly that input, e.g. {"UVUSEE_SIZE.megapixels": 2.25}

run() returns the images saved by the node titled `output` (a SaveImage or
PreviewImage node), or by every output node if `output` is None.

The seed of the node titled `seed_node` (its "seed" or "noise_seed" input) is set
to `seed`, or a random value if None, so repeated runs aren't served from
ComfyUI's cache. With seed_node=None, every seed input in the graph is set.
Every failure raises ComfyError.
"""

import copy
import json
import os
import random
import uuid
from pathlib import Path

import requests
import websocket  # pip install websocket-client

COMFY = os.environ.get("COMFY_HOST", "127.0.0.1:8188")
TIMEOUT = 600  # seconds for one run
TEXT_FIELDS = ("text", "value", "prompt", "string")  # CLIPTextEncode, Primitive*, TextEncode*Edit, ...
SEED_FIELDS = ("seed", "noise_seed")                  # KSampler, KSamplerAdvanced, RandomNoise


class ComfyError(Exception):
    pass


class Workflow:
    def __init__(self, source: str | Path | dict, require: tuple[str, ...] = (), output: str | None = None,
                 seed_node: str | None = None):
        """source: path to an API-format JSON file, or the dict itself.
        require: titles that must exist exactly once; checked now, not per request.
        output: title of the node whose images run() returns.
        seed_node: title of the sampler whose seed is set on every run."""
        self.graph = source if isinstance(source, dict) else json.loads(Path(source).read_text())
        if not all(isinstance(n, dict) and "class_type" in n for n in self.graph.values()):
            raise ComfyError("not an API-format workflow: export it with Workflow > Export (API)")
        self.titles: dict[str, list[str]] = {}
        for node_id, node in self.graph.items():
            title = node.get("_meta", {}).get("title")
            if title:
                self.titles.setdefault(title, []).append(node_id)
        for title in require:
            self.node_id(title)
        self.output = output
        self.output_id = self.node_id(output) if output else None
        self.seed_ids = [self.node_id(seed_node)] if seed_node else list(self.graph)
        if seed_node and not self._seed_fields(self.graph[self.seed_ids[0]]):
            raise ComfyError(f"node {seed_node!r} has no seed input to set (or it is linked to another node)")

    def node_id(self, title: str) -> str:
        ids = self.titles.get(title, [])
        if len(ids) != 1:
            problem = "no node" if not ids else f"{len(ids)} nodes ({', '.join(ids)})"
            raise ComfyError(f"{problem} titled {title!r} in the workflow")
        return ids[0]

    def fill(self, values: dict, seed: int | None = None) -> dict:
        """Return a copy of the graph with values set. Images must already be
        uploaded file names here; run() does the uploading."""
        graph = copy.deepcopy(self.graph)
        for key, value in values.items():
            title, _, field = key.partition(".")
            inputs = graph[self.node_id(title)]["inputs"]
            if not field:
                field = "image" if self._is_image(value) else self._text_field(title, inputs)
            if field not in inputs:
                raise ComfyError(f"node {title!r} has no input {field!r}")
            if isinstance(inputs[field], list):
                raise ComfyError(f"input {title}.{field} is linked to another node; set the source node instead")
            inputs[field] = value.name if self._is_image(value) else value

        seed = random.randrange(2**63) if seed is None else seed
        for node_id in self.seed_ids:
            for field in self._seed_fields(graph[node_id]):
                graph[node_id]["inputs"][field] = seed
        return graph

    def run(self, values: dict, seed: int | None = None, host: str = COMFY) -> list[bytes]:
        """Upload images, queue the workflow, wait, and return every saved image as PNG bytes."""
        http, client_id = f"http://{host}", uuid.uuid4().hex
        try:
            values = {k: _Uploaded(_upload(http, v, client_id)) if isinstance(v, bytes) else v
                      for k, v in values.items()}
            graph = self.fill(values, seed)

            # Listen before queueing so no event is missed
            ws = websocket.create_connection(f"ws://{host}/ws?clientId={client_id}", timeout=TIMEOUT)
            try:
                r = requests.post(f"{http}/prompt", json={"prompt": graph, "client_id": client_id}, timeout=30)
                if r.status_code != 200:
                    raise ComfyError(f"workflow rejected: {r.text[:1000]}")
                prompt_id = r.json()["prompt_id"]
                _wait(ws, prompt_id)
            finally:
                ws.close()

            outputs = requests.get(f"{http}/history/{prompt_id}", timeout=30).json()[prompt_id]["outputs"]
            if self.output_id:
                files = outputs.get(self.output_id, {}).get("images", [])
                if not files:
                    raise ComfyError(f"node {self.output!r} produced no images; it must be a SaveImage or "
                                     "PreviewImage node")
            else:
                files = [img for out in outputs.values() for img in out.get("images", [])]
                files = [f for f in files if f.get("type") == "output"] or files  # SaveImage first, else previews
                if not files:
                    raise ComfyError("the workflow finished but produced no images")
            return [requests.get(f"{http}/view", params=f, timeout=30).content for f in files]

        except ComfyError:
            raise
        except (requests.RequestException, websocket.WebSocketException, OSError, KeyError) as e:
            raise ComfyError(f"{type(e).__name__}: {e}") from e

    @staticmethod
    def _seed_fields(node: dict) -> list[str]:
        return [f for f in SEED_FIELDS if isinstance(node["inputs"].get(f), int)]

    @staticmethod
    def _is_image(value) -> bool:
        return isinstance(value, _Uploaded)

    @staticmethod
    def _text_field(title: str, inputs: dict) -> str:
        for field in TEXT_FIELDS:
            if isinstance(inputs.get(field), str):
                return field
        raise ComfyError(f"node {title!r} has no text input; use '{title}.<field>' to name it")


class _Uploaded(str):
    """An uploaded file name, so fill() knows to set the node's "image" input."""
    @property
    def name(self) -> str:
        return str(self)


def _upload(http: str, data: bytes, client_id: str) -> str:
    # Unique name so concurrent requests never overwrite each other's input
    r = requests.post(f"{http}/upload/image", files={"image": (f"{client_id}_{uuid.uuid4().hex[:8]}.png", data)},
                      timeout=30)
    r.raise_for_status()
    info = r.json()
    return f"{info['subfolder']}/{info['name']}" if info.get("subfolder") else info["name"]


def _wait(ws, prompt_id: str) -> None:
    while True:
        msg = ws.recv()
        if isinstance(msg, bytes):  # preview frames
            continue
        msg = json.loads(msg)
        data = msg.get("data", {})
        if data.get("prompt_id") != prompt_id:
            continue
        if msg["type"] == "execution_error":
            raise ComfyError(f"{data.get('node_type')} failed: {data.get('exception_message', '').strip()}")
        if msg["type"] == "executing" and data.get("node") is None:  # finished, history written
            return