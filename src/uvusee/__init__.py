from fastapi import FastAPI, File, Form, UploadFile, HTTPException
from fastapi.responses import PlainTextResponse, Response
import uvicorn
from .ming_client import edit, MingError

app = FastAPI()

@app.post("/texture")
async def texture(
    image: UploadFile = File(...),
    prompt: str = Form(...),
    layout: str = Form("horizontal_cross"),
    face_size: int = Form(512),
    faces: str = Form("{}"),
):
    # file_path = os.path.join("uploads", "cubemap.png")
    # data = await image.read()
    # with open(file_path, "wb+") as f:
    #     f.write(data)

    # print(f"Received {image.filename} ({len(data)} bytes), prompt={prompt!r}, "
    #       f"layout={layout}, face_size={face_size}, faces={faces}")
    # return PlainTextResponse("hello")
    try:
        return Response(edit(image.file.read(), prompt), media_type="image/png")
    except MingError as e:
        raise HTTPException(status_code=502, detail=str(e))

def main() -> None:
    uvicorn.run(app, host="127.0.0.1", port=8000)