# launch/webrtc.launch.py
from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument
from launch.substitutions import LaunchConfiguration
from launch_ros.actions import Node


def generate_launch_description():
    return LaunchDescription([
        DeclareLaunchArgument(
            "robot_id",
            default_value="69064ea29c7b3b10f2a0dc67",
            description="Unique ID of the robot"
        ),
        DeclareLaunchArgument(
            "signaling_url",
            default_value="ws://10.0.0.69:3000/signal",
            description="WebSocket URL of the signaling server"
        ),
        DeclareLaunchArgument(
            "auth_token",
            default_value="",
            description="Optional auth token for signaling server"
        ),
        DeclareLaunchArgument(
            "socketio_namespace",
            default_value="",
            description="Signaling server Socket.IO namespace"
        ),
        DeclareLaunchArgument(
            "ice_servers",
            default_value="stun:stun.l.google.com:19302,turn:10.0.0.69?transport=udp,turn:10.0.0.69:3478?transport=tcp",
            description="Comma-separated STUN/TURN URLs (e.g. turn:host:3478)"
        ),
        DeclareLaunchArgument(
            "ice_username",
            default_value="",
            description="Username for TURN servers (if required)"
        ),
        DeclareLaunchArgument(
            "ice_password",
            default_value="",
            description="Password for TURN servers (if required)"
        ),
        Node(
            package="webrtc",
            executable="webrtc_node",
            name="webrtc_client",
            output="screen",
            parameters=[{
                "robot_id": LaunchConfiguration("robot_id"),
                "signaling_url": LaunchConfiguration("signaling_url"),
                "auth_token": LaunchConfiguration("auth_token"),
                "socketio_namespace": LaunchConfiguration("socketio_namespace"),
                "ice_servers": LaunchConfiguration("ice_servers"),
                "ice_username": LaunchConfiguration("ice_username"),
                "ice_password": LaunchConfiguration("ice_password"),
            }],
        ),
    ])
