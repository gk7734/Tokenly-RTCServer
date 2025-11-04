mod signaling_server;

use axum::{
    routing::get,
    Router,
};
use tower::ServiceBuilder;
use tower_http::cors::CorsLayer;
use tracing_subscriber;
use signaling_server::{SignalingState, nestjs_websocket_handler, connection_status_handler};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    // 로깅 초기화
    tracing_subscriber::fmt::init();

    // 시그널링 서버 상태 생성
    let signaling_state = SignalingState::new();

    // 라우터 설정 - NestJS 서버와만 통신
    println!("Setting up signaling server for NestJS communication...");
    let app = Router::new()
        .route("/rtc", get(nestjs_websocket_handler))  // NestJS와 WebSocket 연결
        .route("/status", get(connection_status_handler))  // 연결 상태 확인
        .layer(
            ServiceBuilder::new()
                .layer(CorsLayer::permissive())
        )
        .with_state(signaling_state);
    println!("Signaling server routes configured.");

    // 서버 시작 - NestJS 전용 포트
    let listener = tokio::net::TcpListener::bind("0.0.0.0:3002").await?;
    println!("Signaling server running on http://127.0.0.1:3002");
    println!("NestJS WebSocket endpoint: ws://127.0.0.1:3002/rtc");

    axum::serve(listener, app).await?;

    Ok(())
}