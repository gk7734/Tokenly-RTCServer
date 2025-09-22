use axum::{
    extract::{
        ws::{Message, WebSocket, WebSocketUpgrade},
        Path, Query, State,
    },
    http::StatusCode,
    response::{Html, IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use serde::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    sync::Arc,
    time::{Duration, SystemTime},
};
use tokio::sync::{broadcast, RwLock};
use tower_http::cors::CorsLayer;
use tracing::{info, warn};
use uuid::Uuid;
use webrtc::{
    api::{
        interceptor_registry::register_default_interceptors,
        media_engine::{MediaEngine, MIME_TYPE_VP8},
        APIBuilder,
    },
    ice_transport::{
        ice_candidate::{RTCIceCandidate, RTCIceCandidateInit},
        ice_server::RTCIceServer,
    },
    interceptor::registry::Registry,
    peer_connection::{
        configuration::RTCConfiguration, peer_connection_state::RTCPeerConnectionState,
        sdp::session_description::RTCSessionDescription, RTCPeerConnection,
    },
    rtp_transceiver::rtp_codec::{RTCRtpCodecCapability, RTPCodecType},
};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum SignalingMessage {
    #[serde(rename = "offer")]
    Offer { sdp: String, session_id: String, room_id: String },
    #[serde(rename = "answer")]
    Answer { sdp: String, session_id: String, room_id: String },
    #[serde(rename = "ice-candidate")]
    IceCandidate {
        candidate: String,
        sdpMid: Option<String>,
        sdpMlineIndex: Option<u16>,
        session_id: String,
        room_id: String,
    },
    #[serde(rename = "join-room")]
    JoinRoom { room_id: String, session_id: String, success: bool },
    #[serde(rename = "leave-room")]
    LeaveRoom { session_id: String, success: bool },
    #[serde(rename = "user-left")]
    UserLeft { session_id: String },
    #[serde(rename = "connected")]
    Connected { session_id: String, timestamp: u64 },
    #[serde(rename = "participants")]
    Participants { participants: Vec<String> },
}

#[derive(Debug, Clone)]
pub struct Session {
    pub id: String,
    pub room_id: Option<String>,
    pub peer_connection: Option<Arc<RTCPeerConnection>>,
    pub created_at: SystemTime,
}

#[derive(Debug, Clone)]
pub struct Room {
    pub room_id: String,
    pub participants: Vec<String>,
}

#[derive(Clone)]
pub struct AppState {
    pub sessions: Arc<RwLock<HashMap<String, Session>>>,
    pub rooms: Arc<RwLock<HashMap<String, Room>>>,
    pub message_sender: broadcast::Sender<(String, SignalingMessage)>
}

impl AppState {
    pub fn new() -> Self {
        let (tx, _) = broadcast::channel(1000);
        Self {
            sessions: Arc::new(RwLock::new(HashMap::new())),
            rooms: Arc::new(RwLock::new(HashMap::new())),
            message_sender: tx,
        }
    }
}

#[tokio::main]
async fn main() {
    let app = Router::new().route("/", get(|| async { "Hello, World!" }));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:8080").await.unwrap();
    axum::serve(listener, app).await.unwrap();
}