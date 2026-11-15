from fastapi import FastAPI, File, Form, UploadFile
from fastapi.responses import PlainTextResponse
import uvicorn
import os

app = FastAPI()


@app.post("/texture")
async def texture(
    image: UploadFile = File(...),
    prompt: str = Form(...),
    layout: str = Form("horizontal_cross"),
    face_size: int = Form(512),
    faces: str = Form("{}"),
):
    file_path = os.path.join("uploads", "cubemap.png")
    data = await image.read()
    with open(file_path, "wb+") as f:
        f.write(data)

    print(f"Received {image.filename} ({len(data)} bytes), prompt={prompt!r}, "
          f"layout={layout}, face_size={face_size}, faces={faces}")
    return PlainTextResponse("hello")

def main() -> None:
    uvicorn.run(app, host="127.0.0.1", port=8000)