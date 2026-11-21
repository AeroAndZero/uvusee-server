import threading
import uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import uvicorn
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import JSONResponse, Response

from .comfy_client import ComfyError, Workflow

# Every workflow needs one node each titled UVUSEE_IMAGE, UVUSEE_PROMPT,
# UVUSEE_KSAMPLER (its seed is randomised per job) and UVUSEE_OUTPUT (the
# SaveImage whose picture is returned). Loaded and checked at startup, so a bad
# export fails here, not on a request.
WORKFLOW_DIR = Path(__file__).parent / "workflows"
TITLES = dict(require=("UVUSEE_IMAGE", "UVUSEE_PROMPT"), output="UVUSEE_OUTPUT", seed_node="UVUSEE_KSAMPLER")
WORKFLOWS = {
    "flux2_klein": Workflow(WORKFLOW_DIR / "flux2_klein_9b_workflow_api.json", **TITLES),
    "ming": Workflow(WORKFLOW_DIR / "ming_image_edit_workflow_api.json", **TITLES),
}
DEFAULT_WORKFLOW = "flux2_klein"

app = FastAPI()

# One worker: ComfyUI renders one job at a time anyway, so jobs wait here in order
# and "queued" / "running" are accurate. Jobs live in memory: run a single
# uvicorn worker, and jobs are lost on restart.
executor = ThreadPoolExecutor(max_workers=1)
jobs: dict[str, dict] = {}
lock = threading.Lock()


def run_job(job_id: str, workflow: Workflow, image: bytes, prompt: str) -> None:
    with lock:
        jobs[job_id]["status"] = "running"
    try:
        result = workflow.run({"UVUSEE_IMAGE": image, "UVUSEE_PROMPT": prompt})[0]
        update = {"status": "done", "result": result}
    except ComfyError as e:
        update = {"status": "failed", "error": str(e)}
    except Exception as e:  # never leave a job stuck in "running"
        update = {"status": "failed", "error": f"{type(e).__name__}: {e}"}
    with lock:
        jobs[job_id].update(update)

@app.get("/")
async def hello():
    return "Server is up and running. Use '/texture' path for the plugin"

@app.post("/texture", status_code=202)
async def texture(
    image: UploadFile = File(...),
    prompt: str = Form(...),
    layout: str = Form("horizontal_cross"),
    face_size: int = Form(512),
    faces: str = Form("{}"),
    workflow: str = Form(DEFAULT_WORKFLOW),
):
    if workflow not in WORKFLOWS:
        raise HTTPException(status_code=400, detail=f"unknown workflow; choose one of {sorted(WORKFLOWS)}")
    data = await image.read()  # read now: the upload is closed once this request returns
    job_id = uuid.uuid4().hex
    with lock:
        jobs[job_id] = {"status": "queued", "workflow": workflow,
                        "layout": layout, "face_size": face_size, "faces": faces}
    executor.submit(run_job, job_id, WORKFLOWS[workflow], data, prompt)
    return JSONResponse(
        status_code=202,
        content={"job_id": job_id, "status": "queued", "status_url": f"/texture/{job_id}"},
        headers={"Location": f"/texture/{job_id}"},
    )


@app.get("/texture/{job_id}")
def texture_status(job_id: str):
    with lock:
        job = jobs.get(job_id)
        if job is None:
            raise HTTPException(status_code=404, detail="unknown job")
        body = {"job_id": job_id, "status": job["status"]}
        if job["status"] == "queued":
            ahead = [j for j in jobs.values() if j["status"] in ("queued", "running")]
            body["position"] = next(i for i, j in enumerate(ahead) if j is job)  # jobs ahead of this one
        elif job["status"] == "done":
            body["result_url"] = f"/texture/{job_id}/result"
        elif job["status"] == "failed":
            body["error"] = job["error"]
    return body


@app.get("/texture/{job_id}/result")
def texture_result(job_id: str):
    with lock:
        job = jobs.get(job_id)
    if job is None:
        raise HTTPException(status_code=404, detail="unknown job")
    if job["status"] == "failed":
        raise HTTPException(status_code=502, detail=job["error"])
    if job["status"] != "done":
        raise HTTPException(status_code=409, detail=f"job is {job['status']}, not done yet")
    return Response(job["result"], media_type="image/png")


def main() -> None:
    uvicorn.run(app, host="0.0.0.0", port=8189)