//! Length-prefixed frame codec for the Codex IPC transport.

use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

use crate::error::TransportError;

/// Maximum allowed frame size (256 MiB).
pub const MAX_FRAME_SIZE: u32 = 256 * 1024 * 1024;

/// Read a single length-prefixed frame from the reader.
///
/// Wire format: 4-byte little-endian u32 length, followed by that many bytes
/// of UTF-8 payload.
pub async fn read_frame<R: AsyncRead + Unpin>(reader: &mut R) -> Result<String, TransportError> {
    let mut len_buf = [0u8; 4];
    let n = reader.read(&mut len_buf).await?;
    if n == 0 {
        return Err(TransportError::ConnectionClosed);
    }
    // If we got a partial length header, read the rest.
    if n < 4 {
        reader.read_exact(&mut len_buf[n..]).await?;
    }

    let length = u32::from_le_bytes(len_buf);

    if length > MAX_FRAME_SIZE {
        return Err(TransportError::FrameTooLarge {
            size: length,
            max: MAX_FRAME_SIZE,
        });
    }

    if length == 0 {
        return Ok(String::new());
    }

    let mut buf = vec![0u8; length as usize];
    reader.read_exact(&mut buf).await?;

    String::from_utf8(buf).map_err(|_| TransportError::InvalidUtf8)
}

/// Write a single length-prefixed frame to the writer.
pub async fn write_frame<W: AsyncWrite + Unpin>(
    writer: &mut W,
    payload: &str,
) -> Result<(), TransportError> {
    let length = payload.len() as u32;
    writer.write_all(&length.to_le_bytes()).await?;
    writer.write_all(payload.as_bytes()).await?;
    writer.flush().await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn roundtrip() {
        let (mut client, mut server) = tokio::io::duplex(1024);
        let msg = "hello, codex ipc!";

        write_frame(&mut client, msg).await.unwrap();
        let result = read_frame(&mut server).await.unwrap();
        assert_eq!(result, msg);
    }

    #[tokio::test]
    async fn empty_frame() {
        let (mut client, mut server) = tokio::io::duplex(1024);

        write_frame(&mut client, "").await.unwrap();
        let result = read_frame(&mut server).await.unwrap();
        assert_eq!(result, "");
    }

    #[tokio::test]
    async fn frame_too_large() {
        let bad_len = (MAX_FRAME_SIZE + 1).to_le_bytes();
        let mut reader = &bad_len[..];

        // We need an AsyncRead, so wrap in a Cursor.
        let mut cursor = tokio::io::BufReader::new(&mut reader);
        let err = read_frame(&mut cursor).await.unwrap_err();
        assert!(
            matches!(err, TransportError::FrameTooLarge { size, max } if size == MAX_FRAME_SIZE + 1 && max == MAX_FRAME_SIZE)
        );
    }

    #[tokio::test]
    async fn multi_frame_sequence() {
        let (mut client, mut server) = tokio::io::duplex(4096);
        let messages = ["first", "second", "third", ""];

        for msg in &messages {
            write_frame(&mut client, msg).await.unwrap();
        }

        for msg in &messages {
            let result = read_frame(&mut server).await.unwrap();
            assert_eq!(&result, msg);
        }
    }

    #[tokio::test]
    async fn connection_closed() {
        let (_, mut server) = tokio::io::duplex(1024);
        // Client side is dropped, so reads should see EOF.
        let err = read_frame(&mut server).await.unwrap_err();
        assert!(matches!(err, TransportError::ConnectionClosed));
    }
}
