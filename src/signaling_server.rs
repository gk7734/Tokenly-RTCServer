use axum::{
    extract::{
        ws::{Message, WebSocket, WebSocketUpgrade},
        State,
    },
    response::Response,
};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::RwLock;
use futures_util::{SinkExt, StreamExt};

// NestJS와 주고받는 시그널링 메시지 프로토콜
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum SignalingMessage {
    // NestJS로부터 받는 시그널링 메시지들
    #[serde(rename = "create-peer")]
    CreatePeer {
        session_id: String,
        room_id: String,
    },
    #[serde(rename = "destroy-peer")]
    DestroyPeer {
        session_id: String,
    },

    // NestJS로 보내는 응답 메시지들
    #[serde(rename = "peer-created")]
    PeerCreated {
        session_id: String,
        success: bool,
    },
    #[serde(rename = "peer-destroyed")]
    PeerDestroyed {
        session_id: String,
    },
}

// 시그널링 서버 상태 (TURN 설정 정보만 관리)
#[derive(Clone)]
pub struct SignalingState {
    pub active_sessions: Arc<RwLock<HashMap<String, SessionInfo>>>,
    pub nestjs_sender: Arc<RwLock<Option<tokio::sync::mpsc::UnboundedSender<Result<Message, axum::Error>>>>>,
}

// 세션 정보 (최소한의 정보만 저장)
#[derive(Debug, Clone)]
pub struct SessionInfo {
    pub session_id: String,
    pub room_id: String,
    pub created_at: std::time::SystemTime,
}

impl SignalingState {
    pub fn new() -> Self {
        Self {
            active_sessions: Arc::new(RwLock::new(HashMap::new())),
            nestjs_sender: Arc::new(RwLock::new(None)),
        }
    }

    // TURN 서버 정보만 제공 (실제 WebRTC 연결은 브라우저 간 P2P)
    pub async fn provide_turn_config(&self, session_id: String, room_id: String) -> Result<bool, Box<dyn std::error::Error>> {
        println!("Providing TURN server config for browser P2P: session_id={}, room_id={}", session_id, room_id);

        // 세션 정보 저장
        let session_info = SessionInfo {
            session_id: session_id.clone(),
            room_id,
            created_at: std::time::SystemTime::now(),
        };

        let mut sessions = self.active_sessions.write().await;
        sessions.insert(session_id, session_info);

        // TURN 서버 정보 제공 성공
        Ok(true)
    }

    // 세션 제거
    pub async fn destroy_session(&self, session_id: &str) {
        let mut sessions = self.active_sessions.write().await;
        if let Some(_) = sessions.remove(session_id) {
            println!("Session destroyed: {}", session_id);
        }
    }

    // 활성 세션 수 조회
    pub async fn get_active_sessions_count(&self) -> usize {
        let sessions = self.active_sessions.read().await;
        sessions.len()
    }
}

// NestJS와 WebSocket 연결 핸들러
pub async fn nestjs_websocket_handler(
    ws: WebSocketUpgrade,
    State(state): State<SignalingState>,
) -> Response {
    println!("NestJS WebSocket connection request received");
    ws.on_upgrade(|socket| handle_nestjs_socket(socket, state))
}

// NestJS와의 WebSocket 연결 처리
async fn handle_nestjs_socket(socket: WebSocket, state: SignalingState) {
    println!("NestJS connected to signaling server");

    let (sender, mut receiver) = socket.split();
    let (tx, rx) = tokio::sync::mpsc::unbounded_channel();

    // NestJS 전송 채널 저장
    {
        let mut nestjs_sender = state.nestjs_sender.write().await;
        *nestjs_sender = Some(tx.clone());
    }

    // 송신 태스크
    let sender_task = {
        let mut rx = tokio_stream::wrappers::UnboundedReceiverStream::new(rx);
        let mut sender = sender;
        tokio::spawn(async move {
            use futures_util::StreamExt;
            while let Some(msg) = rx.next().await {
                if let Ok(message) = msg {
                    if sender.send(message).await.is_err() {
                        println!("Failed to send message to NestJS");
                        break;
                    }
                } else {
                    break;
                }
            }
            println!("NestJS sender task ended");
        })
    };

    // 수신 태스크
    let state_clone = state.clone();
    let receiver_task = tokio::spawn(async move {
        use futures_util::StreamExt;
        while let Some(msg) = receiver.next().await {
            match msg {
                Ok(Message::Text(text)) => {
                    match serde_json::from_str::<SignalingMessage>(&text) {
                        Ok(signaling_msg) => {
                            handle_signaling_message(signaling_msg, &state_clone, &tx).await;
                        }
                        Err(e) => {
                            println!("Failed to parse signaling message: {} - Raw: {}", e, text);
                        }
                    }
                }
                Ok(Message::Close(_)) => {
                    println!("NestJS disconnected from signaling server");
                    break;
                }
                Ok(Message::Ping(data)) => {
                    if let Err(_) = tx.send(Ok(Message::Pong(data))) {
                        break;
                    }
                }
                Ok(_) => {}
                Err(e) => {
                    println!("NestJS WebSocket error: {}", e);
                    break;
                }
            }
        }
        println!("NestJS receiver task ended");
    });

    // 태스크 완료 대기
    tokio::select! {
        _ = sender_task => {},
        _ = receiver_task => {},
    }

    // 정리
    println!("NestJS connection cleanup");
    let mut nestjs_sender = state.nestjs_sender.write().await;
    *nestjs_sender = None;
}

// 시그널링 메시지 처리
async fn handle_signaling_message(
    message: SignalingMessage,
    state: &SignalingState,
    tx: &tokio::sync::mpsc::UnboundedSender<Result<Message, axum::Error>>,
) {
    match message {
        SignalingMessage::CreatePeer { session_id, room_id } => {
            println!("Browser requesting peer creation: session_id={}, room_id={} - providing TURN server info for P2P", session_id, room_id);

            // TURN 서버 정보 제공 (실제 WebRTC 연결은 브라우저 간 직접)
            match state.provide_turn_config(session_id.clone(), room_id).await {
                Ok(_) => {
                    let response = SignalingMessage::PeerCreated {
                        session_id,
                        success: true,
                    };
                    let _ = tx.send(Ok(Message::Text(serde_json::to_string(&response).unwrap())));
                }
                Err(e) => {
                    println!("Failed to provide TURN config: {}", e);
                    let response = SignalingMessage::PeerCreated {
                        session_id,
                        success: false,
                    };
                    let _ = tx.send(Ok(Message::Text(serde_json::to_string(&response).unwrap())));
                }
            }
        }
        SignalingMessage::DestroyPeer { session_id } => {
            println!("Destroying session: {}", session_id);
            state.destroy_session(&session_id).await;

            let response = SignalingMessage::PeerDestroyed {
                session_id,
            };
            let _ = tx.send(Ok(Message::Text(serde_json::to_string(&response).unwrap())));
        }
        _ => {
            println!("Unhandled signaling message type");
        }
    }
}