use tokio::{io::{AsyncReadExt, AsyncWriteExt}, net::{TcpListener, TcpStream}, sync::{broadcast::{self, Receiver, error::RecvError}, mpsc}};
use tracing::warn;
use std::{io, net::SocketAddr };


// 처음부터 socket이 mut으로 정의될 필요는 없음. 

// _guard는 main process가 안전하게 종료하기 위한 꼼수 sender가 0이되면 recv는 None을 받음. 
async fn process(
    mut socket: TcpStream,
    mut shutdown : Receiver<()>, 
    _guard : mpsc::Sender<()>
    ) -> io::Result<()>
{
    let mut buf = [0u8; 1024]; // 0u8 -> byte, 1024는 개수다.

    loop{
        tokio::select!{
            // res = socket.read를 해서 읽은 데이터 -> 값이 0이면 리턴하고 아니면 echo 찍음
            res = socket.read(&mut buf) => {
                let n = res?;

                if n == 0 {
                    return Ok(());        
                }

                println!("recv: {n}");
                socket.write_all(&buf[..n]).await?; // buf의 n까지에 해당하는 bytes를 Echo
            }

            // _ = shutdown 신호를 받아서 -> return OK 한다.
            _ = shutdown.recv() => {
                return Ok(());
            }
        }
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

    // 모든 Task들의 Process가 끝났음을 알게하는 mpsc 구조 Task에 mpsc_tx를 Clone해서 넣어야함
    // Receiver는 mut을 제약으로 받는데, mpsc구조의 consumer는 오직 하나라서
    // mut은 rust에서 값을 바꾸는 주체는 오직 여기 하나라는 보장을 함.
    let (mpsc_tx, mut mpsc_rx) = mpsc::channel(1);

    // Ctrl+c Trigger -> 모든 Task 종료신호.
    let (shutdown_tx, _) = broadcast::channel::<()>(1);


    loop { 
        // tokio::select!는 패턴 = Future식 => {핸들러}
        // Future식은, await에서 땐거
        // 핸들러에는 그 분기가 이겼을떄 실행하는 코드로 뭐든 써도됨.
        tokio::select! {    

            // Accept Future    
            res = listener.accept() => {
                let (socket, addr) = match res { 
                    Ok(pair) => pair,
                    Err(e) => {
                        warn!(%e, "tcp accept failed");
                        continue;
                    }
                };

                println!("new client: {addr}"); 
                
                // shutdown_tx -> shutdown_rx의 subscribe들에게 broadcast
                // tx.subscribe() 이후에 rx.recv().await? 로 메세지 전달 받기 가능함.
                
                let shutdown_rx = shutdown_tx.subscribe();

                // Task의 종료를 모르니까 async move로 소유권 넘김
                // Task가 Worker Thread를 넘나들 수 있어서 await를 넘나드는 모든값이 스레드간 이동 가능해야함
                // Rc나 std::sync::MutexGuard같은거 들고있으면 에러남
                let guard = mpsc_tx.clone();
                tokio::spawn(async move{
                    if let Err(e) = process(socket, shutdown_rx, guard).await{
                        warn!(%addr, %e, "connection error");
                    }
                });   
            }         

            // ctrl_c 이벤트 Future
            _ = tokio::signal::ctrl_c() => {
                warn!("ctrl-c event spawned, All-Task Terminated");
                break;
            }
        }
    }

    let _ = shutdown_tx.send(()); // 그냥 셧다운이 됬다고 전송만 (데이터 없음), 0이면 err오는데 ㄱㅊ음

    drop(mpsc_tx); // 
    mpsc_rx.recv().await; // 무조건 None임.    
    return Ok(());    
}
