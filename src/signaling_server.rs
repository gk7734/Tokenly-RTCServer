use axum::{
    extract::{
        ws::{Message, WebSocket, WebSocketUpgrade},
        State,
    },
    response::{Response, Json},
};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::RwLock;
use futures_util::{SinkExt, StreamExt};

// 재연결 설정 상수
const MAX_RECONNECT_ATTEMPTS: usize = 5;
const INITIAL_RECONNECT_DELAY: Duration = Duration::from_secs(1);
const MAX_RECONNECT_DELAY: Duration = Duration::from_secs(30);
const HEARTBEAT_INTERVAL: Duration = Duration::from_secs(30);
const CONNECTION_TIMEOUT: Duration = Duration::from_secs(10);

// 연결 상태
#[derive(Debug, Clone, PartialEq)]
pub enum ConnectionState {
    Connected,
    Disconnected,
    Reconnecting,
    Failed,
}

// 재연결 정보
#[derive(Debug, Clone)]
pub struct ReconnectInfo {
    pub attempts: usize,
    pub next_delay: Duration,
    pub last_attempt: Option<std::time::SystemTime>,
    pub state: ConnectionState,
}

impl ReconnectInfo {
    pub fn new() -> Self {
        Self {
            attempts: 0,
            next_delay: INITIAL_RECONNECT_DELAY,
            last_attempt: None,
            state: ConnectionState::Disconnected,
        }
    }

    pub fn reset(&mut self) {
        self.attempts = 0;
        self.next_delay = INITIAL_RECONNECT_DELAY;
        self.last_attempt = None;
        self.state = ConnectionState::Connected;
    }

    pub fn increment_attempt(&mut self) {
        self.attempts += 1;
        self.last_attempt = Some(std::time::SystemTime::now());
        self.state = ConnectionState::Reconnecting;

        // 지수 백오프: 다음 지연시간을 2배로 증가 (최대 30초)
        self.next_delay = std::cmp::min(
            Duration::from_millis(self.next_delay.as_millis() as u64 * 2),
            MAX_RECONNECT_DELAY
        );
    }

    pub fn should_attempt_reconnect(&self) -> bool {
        self.attempts < MAX_RECONNECT_ATTEMPTS && self.state != ConnectionState::Failed
    }

    pub fn mark_failed(&mut self) {
        self.state = ConnectionState::Failed;
    }
}

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
    pub reconnect_info: Arc<RwLock<ReconnectInfo>>,
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
            reconnect_info: Arc::new(RwLock::new(ReconnectInfo::new())),
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

    // 연결 상태 업데이트
    pub async fn update_connection_state(&self, state: ConnectionState) {
        let mut reconnect_info = self.reconnect_info.write().await;
        reconnect_info.state = state.clone();
        if state == ConnectionState::Connected {
            reconnect_info.reset();
        }
    }

    // 재연결 시도
    pub async fn attempt_reconnect(&self) -> bool {
        let mut reconnect_info = self.reconnect_info.write().await;

        if !reconnect_info.should_attempt_reconnect() {
            reconnect_info.mark_failed();
            return false;
        }

        reconnect_info.increment_attempt();
        let delay = reconnect_info.next_delay;
        let attempt = reconnect_info.attempts;

        drop(reconnect_info);

        println!("재연결 시도 {}/{} - {}초 후 재시도", attempt, MAX_RECONNECT_ATTEMPTS, delay.as_secs());
        tokio::time::sleep(delay).await;

        true
    }

    // 연결 상태 확인
    pub async fn get_connection_state(&self) -> ConnectionState {
        let reconnect_info = self.reconnect_info.read().await;
        reconnect_info.state.clone()
    }
}

// NestJS와 WebSocket 연결 핸들러 (재연결 지원)
pub async fn nestjs_websocket_handler(
    ws: WebSocketUpgrade,
    State(state): State<SignalingState>,
) -> Response {
    println!("NestJS WebSocket connection request received");
    ws.on_upgrade(|socket| handle_nestjs_socket_with_reconnect(socket, state))
}

// 재연결 지원이 포함된 NestJS 소켓 핸들러
async fn handle_nestjs_socket_with_reconnect(socket: WebSocket, state: SignalingState) {
    println!("NestJS WebSocket 연결 시도중...");

    // 연결 상태를 연결됨으로 업데이트
    state.update_connection_state(ConnectionState::Connected).await;

    // 소켓 처리 로직 실행
    let connection_result = handle_nestjs_socket(socket, state.clone()).await;

    // 연결이 끊어진 경우
    state.update_connection_state(ConnectionState::Disconnected).await;

    match connection_result {
        ConnectionResult::NormalClose => {
            println!("NestJS가 정상적으로 연결을 종료했습니다");
        }
        ConnectionResult::NetworkError => {
            println!("네트워크 오류로 인한 연결 끊김");
            // 재연결 로직은 클라이언트(NestJS)에서 처리하도록 함
            // 서버는 연결 실패 상태만 기록
            let mut reconnect_info = state.reconnect_info.write().await;
            reconnect_info.increment_attempt();
        }
    }
}

// 연결 결과 타입
#[derive(Debug)]
enum ConnectionResult {
    NormalClose,
    NetworkError,
}

// NestJS와의 WebSocket 연결 처리 (연결 결과 반환)
async fn handle_nestjs_socket(socket: WebSocket, state: SignalingState) -> ConnectionResult {
    println!("NestJS connected to signaling server");

    let (sender, mut receiver) = socket.split();
    let (tx, rx) = tokio::sync::mpsc::unbounded_channel();

    // NestJS 전송 채널 저장
    {
        let mut nestjs_sender = state.nestjs_sender.write().await;
        *nestjs_sender = Some(tx.clone());
    }

    // 하트비트 태스크
    let heartbeat_tx = tx.clone();
    let heartbeat_task = tokio::spawn(async move {
        let mut interval = tokio::time::interval(HEARTBEAT_INTERVAL);
        loop {
            interval.tick().await;
            if heartbeat_tx.send(Ok(Message::Ping(vec![]))).is_err() {
                break;
            }
        }
    });

    // 송신 태스크 (오류 감지 개선)
    let sender_task = {
        let mut rx = tokio_stream::wrappers::UnboundedReceiverStream::new(rx);
        let mut sender = sender;
        tokio::spawn(async move {
            use futures_util::StreamExt;
            while let Some(msg) = rx.next().await {
                if let Ok(message) = msg {
                    match tokio::time::timeout(CONNECTION_TIMEOUT, sender.send(message)).await {
                        Ok(Ok(_)) => {},
                        Ok(Err(_)) => {
                            println!("WebSocket 송신 오류 - 네트워크 문제 감지");
                            break;
                        }
                        Err(_) => {
                            println!("WebSocket 송신 타임아웃 - 네트워크 문제 감지");
                            break;
                        }
                    }
                } else {
                    break;
                }
            }
            println!("NestJS sender task ended");
        })
    };

    // 수신 태스크 (오류 감지 개선)
    let state_clone = state.clone();
    let receiver_task = tokio::spawn(async move {
        use futures_util::StreamExt;
        let mut pong_received = true;

        while let Ok(msg_result) = tokio::time::timeout(CONNECTION_TIMEOUT * 2, receiver.next()).await {
            match msg_result {
                Some(msg) => {
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
                            println!("NestJS가 정상적으로 연결을 종료함");
                            return ConnectionResult::NormalClose;
                        }
                        Ok(Message::Ping(data)) => {
                            if tx.send(Ok(Message::Pong(data))).is_err() {
                                println!("Ping 응답 실패 - 네트워크 문제 감지");
                                return ConnectionResult::NetworkError;
                            }
                        }
                        Ok(Message::Pong(_)) => {
                            pong_received = true;
                        }
                        Ok(_) => {}
                        Err(e) => {
                            println!("NestJS WebSocket error: {} - 네트워크 문제 감지", e);
                            return ConnectionResult::NetworkError;
                        }
                    }
                }
                None => {
                    println!("WebSocket 스트림 종료 - 네트워크 문제 감지");
                    return ConnectionResult::NetworkError;
                }
            }
        }

        println!("WebSocket 수신 타임아웃 - 네트워크 문제 감지");
        ConnectionResult::NetworkError
    });

    // 태스크 완료 대기 및 결과 반환
    let connection_result = tokio::select! {
        _ = sender_task => ConnectionResult::NetworkError,
        result = receiver_task => result.unwrap_or(ConnectionResult::NetworkError),
        _ = heartbeat_task => ConnectionResult::NetworkError,
    };

    // 정리
    println!("NestJS connection cleanup");
    let mut nestjs_sender = state.nestjs_sender.write().await;
    *nestjs_sender = None;

    connection_result
}

// 연결 상태 응답 구조체
#[derive(Serialize)]
pub struct ConnectionStatus {
    state: String,
    active_sessions: usize,
    reconnect_attempts: usize,
    max_attempts: usize,
    next_delay_seconds: u64,
    last_attempt: Option<String>,
}

// 연결 상태 확인 핸들러
pub async fn connection_status_handler(
    State(state): State<SignalingState>,
) -> Json<ConnectionStatus> {
    let reconnect_info = state.reconnect_info.read().await;
    let active_sessions = state.get_active_sessions_count().await;

    let state_str = match reconnect_info.state {
        ConnectionState::Connected => "connected",
        ConnectionState::Disconnected => "disconnected",
        ConnectionState::Reconnecting => "reconnecting",
        ConnectionState::Failed => "failed",
    };

    let last_attempt_str = reconnect_info.last_attempt.map(|time| {
        time.duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs()
            .to_string()
    });

    Json(ConnectionStatus {
        state: state_str.to_string(),
        active_sessions,
        reconnect_attempts: reconnect_info.attempts,
        max_attempts: MAX_RECONNECT_ATTEMPTS,
        next_delay_seconds: reconnect_info.next_delay.as_secs(),
        last_attempt: last_attempt_str,
    })
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