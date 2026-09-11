use tokio::net::{TcpListener, TcpStream};
use tracing::warn;
use std::{io, net::SocketAddr};

async fn process(socket: TcpStream, addr: SocketAddr)
{
    tracing::info!(peer=%addr, "accepted!");
}

#[tokio::main] // 얘 또한 매크로 
async fn main() -> io::Result<()> {
    println!("Hello from async"); // println!은 매크로 std::io::_print(format_args!(...));

    tracing_subscriber::fmt::init();
    tracing::info!("started");

    // bind는 Future<Output = io::Result<TcpListener>>를 돌려줌 
    // .await는 완료 기다려서, io::Resulkt<TcpListener>를 꺼냄
    // ?는 그 Result를 풀어서 Ok면 안의 값을, Err면 함수 종료하면 에러 반환
    let listener = TcpListener::bind("127.0.0.1:6379").await?; 

    loop { 
        let (socket, addr) = match listener.accept().await {
            Ok(pair) => pair,
            Err(e) => {
                warn!(%e, "tcp accept failed");
                continue;
            }
        };

        println!("new client: {addr}");
        // Task의 종료를 모르니까 async move로 소유권 넘김
        // Task가 Worker Thread를 넘나들 수 있어서 await를 넘나드는 모든값이 스레드간 이동 가능해야함
        // Rc나 std::sync::MutexGuard같은거 들고있으면 에러남
        tokio::spawn(async move{
            process(socket, addr).await
        });
    }

}
