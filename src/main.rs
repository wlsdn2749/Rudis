use tokio::{io::AsyncReadExt, io::AsyncWriteExt, net::{TcpListener, TcpStream}};
use tracing::warn;
use std::{io, net::SocketAddr};

// 처음부터 socket이 mut으로 정의될 필요는 없음. 
async fn process(mut socket: TcpStream, addr: SocketAddr) -> io::Result<()>
{
    tracing::info!(peer=%addr, "accepted!");

    let mut buf = [0u8; 1024]; // 0u8 -> byte, 1024는 개수다.

    loop{
        let n = socket.read(&mut buf).await?;

        if n == 0 {
            return Ok(());        
        }

        println!("recv: {n}");
        socket.write_all(&buf[..n]).await?; // buf의 n까지에 해당하는 bytes를 Echo
    }
    
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
