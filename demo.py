import pyrealsense2 as rs
import numpy as np
import cv2 as cv
import time
import tensorrt as trt
import pycuda.driver as cuda
import pycuda.autoinit
import os

FILE_DIR = os.path.dirname(os.path.abspath(__file__))
ENGINE_PATH = os.path.join(FILE_DIR, "models/yolo11n.engine")


# -----------------------
# YOLO / TensorRT Settings
# -----------------------
INPUT_W = 640
INPUT_H = 640
CONF_THRESH = 0.35
IOU_THRESH = 0.45

# Only focus on person (COCO class 0)
PERSON_CLASS_ID = 0

# -----------------------
# Helper: IoU Calculation
# -----------------------
def compute_iou(boxA, boxB):
    # box: (left, top, right, bottom)
    xA = max(boxA[0], boxB[0])
    yA = max(boxA[1], boxB[1])
    xB = min(boxA[2], boxB[2])
    yB = min(boxA[3], boxB[3])

    interArea = max(0, xB - xA) * max(0, yB - yA)
    areaA = (boxA[2] - boxA[0]) * (boxA[3] - boxA[1])
    areaB = (boxB[2] - boxB[0]) * (boxB[3] - boxB[1])

    return interArea / (areaA + areaB - interArea + 1e-6)

def nms(dets, iou_thresh=0.45):
    """
    dets: list of [x1, y1, x2, y2, score]
    """
    if len(dets) == 0:
        return []

    dets = sorted(dets, key=lambda x: x[4], reverse=True)
    keep = []

    while dets:
        best = dets.pop(0)
        keep.append(best)
        new_dets = []
        for d in dets:
            if compute_iou(best[:4], d[:4]) < iou_thresh:
                new_dets.append(d)
        dets = new_dets

    return keep

# -----------------------
# TensorRT YOLOv11 wrapper
# -----------------------
class TRT_YOLOv11:
    def __init__(self, engine_path):
        # Set TensorRT logger level to ERROR to suppress INFO/WARNING
        logger = trt.Logger(trt.Logger.ERROR)
        runtime = trt.Runtime(logger)

        with open(engine_path, "rb") as f:
            engine_data = f.read()

        self.engine = runtime.deserialize_cuda_engine(engine_data)
        self.context = self.engine.create_execution_context()

        # Find input / output tensor names
        self.input_name = None
        self.output_name = None

        for i in range(self.engine.num_io_tensors):
            name = self.engine.get_tensor_name(i)
            mode = self.engine.get_tensor_mode(name)
            if mode == trt.TensorIOMode.INPUT:
                self.input_name = name
            else:
                self.output_name = name

        # Set input shape
        self.input_shape = (1, 3, INPUT_H, INPUT_W)
        self.context.set_input_shape(self.input_name, self.input_shape)
        assert self.context.all_binding_shapes_specified, "TensorRT input shapes not fully specified!"

        # Create CUDA stream
        self.stream = cuda.Stream()

        # Allocate buffers
        self._allocate_buffers()
        print(f"[LOG] Model: Ultralytics YOLOv11n (TensorRT) loaded successfully.")

    def _allocate_buffers(self):
        # input
        inp_dtype = trt.nptype(self.engine.get_tensor_dtype(self.input_name))
        self.host_input = np.empty(self.input_shape, dtype=inp_dtype)
        self.device_input = cuda.mem_alloc(self.host_input.nbytes)
        self.context.set_tensor_address(self.input_name, int(self.device_input))

        # output
        out_shape = tuple(self.context.get_tensor_shape(self.output_name))  # (1, 84, 8400)
        out_dtype = trt.nptype(self.engine.get_tensor_dtype(self.output_name))
        self.host_output = np.empty(out_shape, dtype=out_dtype)
        self.device_output = cuda.mem_alloc(self.host_output.nbytes)
        self.context.set_tensor_address(self.output_name, int(self.device_output))

    def infer(self, input_tensor):
        """
        input_tensor: np.ndarray, shape (1,3,H,W), float32
        return: np.ndarray, shape (1,84,8400)
        """
        np.copyto(self.host_input, input_tensor)

        cuda.memcpy_htod_async(self.device_input, self.host_input, self.stream)
        self.context.execute_async_v3(self.stream.handle)
        cuda.memcpy_dtoh_async(self.host_output, self.device_output, self.stream)

        self.stream.synchronize()
        return self.host_output.copy()

# -----------------------
# YOLOv11 output decode (for shape = [1,84,8400])
# -----------------------
def decode_yolov11_persons(output, orig_w, orig_h, conf_thres=0.35):
    """
    output: np.ndarray, shape (1,84,8400)
    return: list of [left, top, right, bottom, score]
            Only keep PERSON_CLASS_ID
    """
    out = output[0]  # [84, 8400]
    if out.shape[0] != 84:
        return []

    # The first 4 elements are [cx, cy, w, h]
    boxes = out[0:4, :]     # [4, 8400]
    scores = out[4:, :]     # [80, 8400]

    # Transpose to [8400, 4] / [8400, 80]
    boxes = boxes.T
    scores = scores.T

    # Get best class and score for each anchor
    cls_ids = np.argmax(scores, axis=1)               # [8400]
    cls_scores = np.max(scores, axis=1)               # [8400]

    # Filter by person class and confidence threshold
    mask = (cls_ids == PERSON_CLASS_ID) & (cls_scores > conf_thres)
    if not np.any(mask):
        return []

    boxes = boxes[mask]
    cls_scores = cls_scores[mask]

    # Convert xywh to xyxy (in 0~INPUT_W/H space)
    cx = boxes[:, 0]
    cy = boxes[:, 1]
    w = boxes[:, 2]
    h = boxes[:, 3]

    x1 = cx - w / 2
    y1 = cy - h / 2
    x2 = cx + w / 2
    y2 = cy + h / 2

    # Scale back to original resolution
    scale_x = orig_w / float(INPUT_W)
    scale_y = orig_h / float(INPUT_H)

    x1 *= scale_x
    x2 *= scale_x
    y1 *= scale_y
    y2 *= scale_y

    dets = []
    for i in range(len(cls_scores)):
        dets.append([
            float(x1[i]), float(y1[i]),
            float(x2[i]), float(y2[i]),
            float(cls_scores[i])
        ])

    # NMS
    dets = nms(dets, IOU_THRESH)
    return dets

# -----------------------
# Preprocess for YOLOv11
# -----------------------
def preprocess(frame):
    """
    frame: BGR (H,W,3)
    return: (1,3,INPUT_H,INPUT_W) float32, normalized
    """
    img = cv.resize(frame, (INPUT_W, INPUT_H))
    img = cv.cvtColor(img, cv.COLOR_BGR2RGB)
    img = img.astype(np.float32) / 255.0
    img = np.transpose(img, (2, 0, 1))      # HWC -> CHW
    img = np.expand_dims(img, axis=0)       # NCHW
    return img

# -----------------------
# RealSense + YOLOv11 main loop
# -----------------------
def main():
    # Print application introduction (SenseEdge Kit Demo)
    print("=" * 60)
    print("📢 SenseEdge Kit Demo: Real-time Social Distancing Monitor")
    print("-" * 60)
    print("Features:")
    print("* **Detection Model**: Ultralytics YOLOv11n (TensorRT) for person detection.")
    print("* **3D Measurement**: RealSense depth camera obtains XYZ coordinates to calculate 3D distance.")
    print("* **Warning**: Bounding box turns **RED** if distance is **less than 0.8 meters**.")
    print("=" * 60)
    
    # RealSense Initialization
    pipeline = rs.pipeline()
    config = rs.config()
    config.enable_stream(rs.stream.depth, 1280, 720, rs.format.z16, 30)
    config.enable_stream(rs.stream.color, 1280, 720, rs.format.bgr8, 30)
    profile = pipeline.start(config)
    aligned_stream = rs.align(rs.stream.color)
    depth_sensor = profile.get_device().first_depth_sensor()
    depth_scale = depth_sensor.get_depth_scale()

    # TensorRT YOLOv11 Initialization
    yolo = TRT_YOLOv11(ENGINE_PATH)

    prev_time = 0.0

    try:
        while True:
            # 1. RealSense frame alignment
            frames = pipeline.wait_for_frames()
            aligned_frames = aligned_stream.process(frames)

            depth_frame = aligned_frames.get_depth_frame()
            color_frame = aligned_frames.get_color_frame()
            if not depth_frame or not color_frame:
                continue

            frame = np.asanyarray(color_frame.get_data())
            depth_image = np.asanyarray(depth_frame.get_data())
            depth_intrin = depth_frame.profile.as_video_stream_profile().intrinsics

            orig_h, orig_w = frame.shape[:2]

            # 2. YOLOv8 Detection
            input_tensor = preprocess(frame)
            output = yolo.infer(input_tensor)  # (1,84,8400)

            dets = decode_yolov11_persons(output, orig_w, orig_h, CONF_THRESH)

            # 3. Get 3D Coordinates
            person_positions = []  # (id, X, Y, Z)
            person_boxes = []      # (id, left, top, right, bottom, depth_m)
            id_counter = 1

            for det in dets:
                left, top, right, bottom, score = det

                left_i = int(max(0, min(orig_w - 1, left)))
                top_i = int(max(0, min(orig_h - 1, top)))
                right_i = int(max(0, min(orig_w - 1, right)))
                bottom_i = int(max(0, min(orig_h - 1, bottom)))

                cx = int((left_i + right_i) / 2)
                cy = int((top_i + bottom_i) / 2)

                cy = max(0, min(cy, depth_image.shape[0] - 1))
                cx = max(0, min(cx, depth_image.shape[1] - 1))

                depth_value = depth_image[cy, cx] * depth_scale  # meter
                X, Y, Z = rs.rs2_deproject_pixel_to_point(
                    depth_intrin, [cx, cy], depth_value
                )

                person_positions.append((id_counter, X, Y, Z))
                person_boxes.append([id_counter, left_i, top_i, right_i, bottom_i, depth_value])
                id_counter += 1

            # 4. IoU + 3D Merge (Handle duplicate detections)
            merged = []
            skip = set()

            for i in range(len(person_boxes)):
                if i in skip:
                    continue

                pid1, l1, t1, r1, b1, d1 = person_boxes[i]
                X1, Y1, Z1 = person_positions[i][1:4]
                box1 = (l1, t1, r1, b1)

                for j in range(i + 1, len(person_boxes)):
                    if j in skip:
                        continue

                    pid2, l2, t2, r2, b2, d2 = person_boxes[j]
                    X2, Y2, Z2 = person_positions[j][1:4]
                    box2 = (l2, t2, r2, b2)

                    iou = compute_iou(box1, box2)
                    dist3d = np.linalg.norm(
                        np.array([X1, Y1, Z1]) - np.array([X2, Y2, Z2])
                    )
                    
                    cx1 = (l1 + r1) * 0.5
                    cy1 = (t1 + b1) * 0.5
                    cx2 = (l2 + r2) * 0.5
                    cy2 = (t2 + b2) * 0.5
                    pixel_dist = ((cx1 - cx2)**2 + (cy1 - cy2)**2) ** 0.5

                    # Merge logic
                    if (iou > 0.25 and dist3d < 0.35) or pixel_dist < 140:
                        skip.add(j)

                merged.append(person_boxes[i])

            person_boxes = merged

            # 5. Inter-person Distance Calculation
            close_pairs = []
            for i in range(len(person_boxes)):
                for j in range(i + 1, len(person_boxes)):
                    pid1, l1, t1, r1, b1, d1 = person_boxes[i]
                    pid2, l2, t2, r2, b2, d2 = person_boxes[j]

                    # Deproject 3D points from box center
                    X1, Y1, Z1 = rs.rs2_deproject_pixel_to_point(
                        depth_intrin, [(l1 + r1) // 2, (t1 + b1) // 2], d1
                    )
                    X2, Y2, Z2 = rs.rs2_deproject_pixel_to_point(
                        depth_intrin, [(l2 + r2) // 2, (t2 + b2) // 2], d2
                    )

                    dist3 = np.linalg.norm(
                        np.array([X1, Y1, Z1]) - np.array([X2, Y2, Z2])
                    )

                    # Check if distance is too close (0.8m threshold)
                    if dist3 < 0.8:
                        close_pairs.append((pid1, pid2, dist3))

            # 6. Draw Bounding Boxes
            for pid, left, top, right, bottom, dist_m in person_boxes:
                color = (0, 255, 0) # Default Green

                # Change to Red if part of a close pair
                for (id1, id2, _) in close_pairs:
                    if pid in (id1, id2):
                        color = (0, 0, 255) # Red Alert

                cv.rectangle(frame, (left, top), (right, bottom), color, 2)
                cv.putText(
                    frame,
                    f"ID {pid}: {dist_m:.2f}m",
                    (left, top - 10),
                    cv.FONT_HERSHEY_SIMPLEX,
                    0.8,
                    (255, 255, 255),
                    2,
                )

            # 7. Draw Warning Text
            y_offset = 80
            for (id1, id2, d) in close_pairs:
                cv.putText(
                    frame,
                    f"ALERT: ID {id1} & ID {id2} TOO CLOSE ({d:.2f}m)",
                    (50, y_offset),
                    cv.FONT_HERSHEY_SIMPLEX,
                    1.0,
                    (0, 0, 255),
                    3,
                )
                y_offset += 40

            # 8. Resize and Display RGB + Depth
            rgb_small = cv.resize(frame, (960, 540))

            # Apply color map for depth visualization
            depth_colormap = cv.applyColorMap(
                cv.convertScaleAbs(depth_image, alpha=0.03),
                cv.COLORMAP_JET
            )
            depth_small = cv.resize(depth_colormap, (960, 540))

            combined = np.hstack((rgb_small, depth_small))

            # 9. FPS Calculation and Display
            curr_time = time.time()
            fps = 1.0 / (curr_time - prev_time) if prev_time else 0.0
            prev_time = curr_time

            cv.putText(
                combined,
                f"FPS: {fps:.1f}",
                (20, 40),
                cv.FONT_HERSHEY_SIMPLEX,
                1,
                (0, 255, 255),
                2,
            )

            # 10. Show Window
            cv.imshow("AVerMedia SenseEdge Kit - Demo", combined)

            key = cv.waitKey(1)
            if key == 27 or key == ord('q'):
                break

    finally:
        pipeline.stop()
        cv.destroyAllWindows()

if __name__ == "__main__":
    main()