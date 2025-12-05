# SenseEdge Kit Quick Start

**SenseEdge Kit** is a plug-and-play depth-sensing development platform that combines the powerful computing capabilities of **NVIDIA Jetson AGX Orin** with the precision of the **Intel RealSense D457** depth camera through a fully integrated **GSML → Jetson interface**.

The kit removes the complex setup of traditional depth camera development—such as driver integration, firmware matching, and kernel modules—allowing developers to focus directly on building AI or robotics applications.

---

## What's in the Box?

* Jetson AGX Orin
* Intel RealSense D457 Depth Camera
* GSML–to–Jetson Adapter Board
* GSML Cable
* Power Adapter

---

## Run the Setup Script

SenseEdge Kit comes with a pre-tested JetPack environment. Please download the quick-start repository and run the setup script:

```bash
git clone https://github.com/AVerMedia-Technologies-Inc/SenseEdge-kit-quick-start.git
cd SenseEdge-kit-quick-start
./setup.sh
```
> [!NOTE]
> The setup script will prompt you to make some choices, such as whether to download the required AI models concurrently. Please follow the instructions to complete the setup.

The `setup.sh` script will automatically perform the following steps:

* Check the system environment (e.g., JetPack version, network connectivity).
* Install `pip` and `venv` (Python virtual environment module).
* Create a dedicated virtual environment named `realsense_env` under the `~/aver/` directory.
* Activate the environment and install required Python libraries (e.g., pycuda, opencv, pyrealsense2).
* Prompt the user to confirm whether to download the necessary AI models concurrently (default: Yes).

### Model Download

If you **did not choose** to download the models during the `setup.sh` script execution, you can run the following command later to download them separately:

```bash
# Ensure you are in the SenseEdge-kit-quick-start directory
./scripts/download_model.sh
```

## Run the Demo

To verify that the RealSense D457 and the AI stack are working properly, we provide a simple Python example. This example covers color and depth streaming, AI inference using a YOLO model, and distance estimation based on depth data.

Follow these steps to activate the virtual environment and run the demo:

1.  **Activate the Virtual Environment:**

    ```bash
    source ~/aver/realsense_env/bin/activate
    ```

2.  **Run the Python Demo:**

    ```bash
    python demo.py
    ```

After execution, you should see real-time color and depth streams, detection bounding boxes, and distance information displayed on the image.

## Customize Your Development

The SenseEdge Kit provides a complete, ready-to-use environment for any depth-camera-based AI or **computer vision application**. The development environment supports core frameworks and libraries like PyTorch, TensorRT, ONNX Runtime, RealSense SDK, and OpenCV.

Once you have access to synchronized color and depth frames, you are free to integrate your own algorithms, models, or processing pipelines, such as:

* Object or person detection
* Pose estimation and segmentation
* 3D scene understanding and depth measurement
* Gesture recognition or human-computer interaction sensing

