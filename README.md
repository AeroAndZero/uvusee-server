# Server for [uvusee-plugin](https://github.com/AeroAndZero/uvusee-plugin)
This is the repo you must use when you want to host your own AI models for the plugin.

## How to setup
1. Clone this repo into your linux or windows machine
2. If on linux, run `bash setup.sh`
3. If on windows, run `setup.bat`
4. These files will download the required files and models needed. 
5. If you manually stop the script, to restart the server simply run the `run.sh` or `run.bat` script.

**It is highly advised to run this on a linux machine**

## Using custom workflows
If you would like to use your custom workflow made in ComfyUI, you must make these changes to your graph:
- Rename load image node to UVUSEE_IMAGE
- Rename prompt node to UVUSEE_PROMPT
- Rename KSampler node to UVUSEE_KSAMPLER
- Rename Save image node to UVUSEE_OUTPUT

After making changes, follow these steps:
- Click on the graph button
- Export the graph with API. (ie. click on the Export (API) button)
- Put the workflow into src/uvusee/workflows folder.
- in `__init__.py`, add your workflow file in the `WORKFLOWS` dictionary
- change `DEFAULT_WORKFLOW` variable to your workflow entry

**IMPORTANT**  
After adding your workflow, make sure you add your models into the `comfy` folder inside the repo.

## Roadmap
- [ ] Add ControlNet workflow to accommodate Depth texture and Normal textures
- [ ] Add inpainting support
- [ ] Add batched image generation mode
