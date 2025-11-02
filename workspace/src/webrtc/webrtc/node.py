# robot/webrtc.py
import asyncio
import json
import time
import threading
from urllib.parse import parse_qsl, urlencode, urlparse, urlunparse

import socketio
from aiortc import RTCPeerConnection, RTCSessionDescription, RTCIceCandidate
from aiortc.rtcdatachannel import RTCDataChannel

import rclpy
from rclpy.node import Node
from rclpy.executors import SingleThreadedExecutor
from std_msgs.msg import Float32


class WebRTCBridge(Node):
    def __init__(self):
        super().__init__("webrtc_client")

        # Declare ROS params with defaults
        self.declare_parameter("robot_id", "robot-001")
        self.declare_parameter("signaling_url", "ws://polyflow.studio/signal")
        self.declare_parameter("auth_token", "")
        self.declare_parameter("socketio_namespace", "")
        self.declare_parameter("socketio_path", "")

        self.robot_id = self.get_parameter("robot_id").get_parameter_value().string_value
        self.signaling_url = self.get_parameter("signaling_url").get_parameter_value().string_value
        self.auth_token = self.get_parameter("auth_token").get_parameter_value().string_value
        self.socketio_namespace = self.get_parameter("socketio_namespace").get_parameter_value().string_value
        self.socketio_path = self.get_parameter("socketio_path").get_parameter_value().string_value

        self.get_logger().info(f"WebRTC client starting for robot_id={self.robot_id}, signaling={self.signaling_url}")

        # ROS pubs/subs
        self.j1_cmd_pub = self.create_publisher(Float32, "/arm/j1/cmd/position", 10)
        self.j1_state_sub = self.create_subscription(
            Float32, "/arm/j1/state/position", self._on_j1_state, 10
        )

        # Holds outbound state channel
        self.state_channel: RTCDataChannel | None = None

    # === ROS Callbacks ===
    def _on_j1_state(self, msg: Float32):
        """When robot publishes state, send it over WebRTC state channel."""
        if self.state_channel and self.state_channel.readyState == "open":
            env = {
                "topic": "robot/arm/j1/state/position",
                "qos": "state",
                "tUnixNanos": int(time.time() * 1e9),
                "payload": {"positionRad": float(msg.data)},
            }
            try:
                self.state_channel.send(json.dumps(env))
            except Exception as e:
                self.get_logger().warn(f"Failed to send state: {e}")

    # === Control handler ===
    def on_control_message(self, data: str):
        try:
            env = json.loads(data)
        except Exception:
            return
        topic = env.get("topic", "")
        if topic == "robot/arm/j1/cmd/position":
            pos = float(env["payload"]["positionRad"])
            msg = Float32()
            msg.data = pos
            self.j1_cmd_pub.publish(msg)
            self.get_logger().info(f"Received control: j1 position={pos}")


async def run_webrtc(node: WebRTCBridge):
    """Main async WebRTC loop using Socket.IO for signaling."""

    parsed = urlparse(node.signaling_url)
    scheme_map = {"ws": "http", "wss": "https"}
    scheme = scheme_map.get(parsed.scheme, parsed.scheme or "http")
    if not parsed.netloc:
        raise ValueError("signaling_url must include a host (e.g. ws://host:port/path)")

    base_url = urlunparse((scheme, parsed.netloc, "", "", "", ""))

    namespace_config = node.socketio_namespace.strip()
    if namespace_config:
        namespace = namespace_config if namespace_config.startswith("/") else f"/{namespace_config}"
    else:
        namespace = "/"

    raw_path = parsed.path or ""

    path_config = node.socketio_path.strip()
    if path_config:
        socketio_path = path_config.lstrip("/")
    elif raw_path and raw_path != "/":
        socketio_path = raw_path.lstrip("/")
    else:
        socketio_path = "socket.io"

    query_pairs = list(parse_qsl(parsed.query, keep_blank_values=True))
    if node.auth_token and not any(key == "token" for key, _ in query_pairs):
        query_pairs.append(("token", node.auth_token))
    connect_query = urlencode(query_pairs)
    connect_url = base_url if not connect_query else f"{base_url}?{connect_query}"

    sio = socketio.AsyncClient(reconnection=True)

    pc = RTCPeerConnection()

    @pc.on("datachannel")
    def on_datachannel(channel: RTCDataChannel):
        node.get_logger().info(f"DataChannel opened: {channel.label}")
        if channel.label == "control":
            @channel.on("message")
            def on_message(message):
                if isinstance(message, bytes):
                    message = message.decode("utf-8", "ignore")
                node.on_control_message(message)
        elif channel.label == "state":
            node.state_channel = channel

    async def emit_message(payload: dict):
        try:
            await sio.emit("message", payload, namespace=namespace)
        except Exception as exc:
            node.get_logger().error(
                f"Failed to emit signaling message '{payload.get('type', '<unknown>')}': {exc}"
            )

    @sio.event
    async def connect():
        node.get_logger().info("Connected to signaling server")
        hello = {"type": "hello", "role": "robot", "robotId": node.robot_id}
        if node.auth_token:
            hello["token"] = node.auth_token
        await emit_message(hello)

    @sio.event
    async def connect_error(data):
        node.get_logger().error(f"Socket.IO connection failed: {data}")

    @sio.event
    async def disconnect():
        node.get_logger().warn("Disconnected from signaling server")

    @sio.on("message", namespace=namespace)
    async def on_message(data):
        if isinstance(data, str):
            try:
                data = json.loads(data)
            except json.JSONDecodeError:
                node.get_logger().warn("Ignoring non-JSON signaling payload")
                return
        if not isinstance(data, dict):
            node.get_logger().warn("Ignoring unexpected signaling payload type")
            return

        msg_type = data.get("type")
        if msg_type == "offer":
            try:
                await pc.setRemoteDescription(
                    RTCSessionDescription(sdp=data["sdp"], type="offer")
                )
            except Exception as exc:
                node.get_logger().error(f"Failed to set remote description: {exc}")
                return

            try:
                answer = await pc.createAnswer()
                await pc.setLocalDescription(answer)
            except Exception as exc:
                node.get_logger().error(f"Failed to create local answer: {exc}")
                return

            response = {
                "type": "answer",
                "robotId": node.robot_id,
                "sdp": pc.localDescription.sdp,
                "to": data.get("from"),
            }
            await emit_message(response)

        elif msg_type == "candidate":
            candidate_payload = data.get("candidate")
            if candidate_payload in (None, "null"):
                node.get_logger().debug("Received end-of-candidates marker")
                try:
                    await pc.addIceCandidate(None)
                except Exception as exc:
                    node.get_logger().warn(f"Failed to signal end-of-candidates: {exc}")
                return

            cand_candidate = None
            cand_mid = data.get("sdpMid")
            cand_index = data.get("sdpMLineIndex")

            if isinstance(candidate_payload, dict):
                cand_candidate = candidate_payload.get("candidate")
                cand_mid = candidate_payload.get("sdpMid", cand_mid)
                cand_index = candidate_payload.get("sdpMLineIndex", cand_index)
            elif isinstance(candidate_payload, str):
                cand_candidate = candidate_payload
            else:
                node.get_logger().warn("Ignoring ICE candidate with unexpected payload type")
                return

            if not cand_candidate:
                node.get_logger().debug("ICE candidate payload missing 'candidate' data")
                return

            try:
                ice_candidate = RTCIceCandidate(
                    sdpMid=cand_mid,
                    sdpMLineIndex=cand_index,
                    candidate=cand_candidate,
                )
                await pc.addIceCandidate(ice_candidate)
            except Exception as exc:
                node.get_logger().warn(f"Failed to add ICE candidate: {exc}")

        else:
            node.get_logger().debug(f"Ignoring unsupported signaling message type: {msg_type}")

    try:
        await sio.connect(
            connect_url,
            transports=["websocket"],
            namespaces=[namespace],
            socketio_path=socketio_path,
            auth={"token": node.auth_token} if node.auth_token else None,
        )
        await sio.wait()
    finally:
        if sio.connected:
            await sio.disconnect()
        await pc.close()


def main(args=None):
    rclpy.init(args=args)
    node = WebRTCBridge()

    # Spin ROS in the background so subscriptions/timers actually run
    executor = SingleThreadedExecutor()
    executor.add_node(node)
    ros_thread = threading.Thread(target=executor.spin, daemon=True)
    ros_thread.start()
    node.get_logger().info("ROS executor started (background thread)")

    # Run the async WebRTC client
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    try:
        node.get_logger().info("Attempting to run the WebRTC client…")
        loop.run_until_complete(run_webrtc(node))
    except KeyboardInterrupt:
        node.get_logger().info("Keyboard interrupt received")
    except Exception as e:
        node.get_logger().error(f"WebRTC loop crashed: {e}")
    finally:
        node.get_logger().info("Shutting down")
        executor.shutdown()
        loop.stop()
        loop.close()
        node.destroy_node()
        rclpy.shutdown()


if __name__ == "__main__":
    main()
