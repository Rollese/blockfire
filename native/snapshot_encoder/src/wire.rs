//! Little-endian wire primitives matching Godot's StreamPeerBuffer defaults.

pub fn put_u8(b: &mut Vec<u8>, v: u8) {
    b.push(v);
}
pub fn put_u16(b: &mut Vec<u8>, v: u16) {
    b.extend_from_slice(&v.to_le_bytes());
}
pub fn put_u32(b: &mut Vec<u8>, v: u32) {
    b.extend_from_slice(&v.to_le_bytes());
}
pub fn put_i32(b: &mut Vec<u8>, v: i32) {
    b.extend_from_slice(&v.to_le_bytes());
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn little_endian_widths() {
        let mut b = Vec::new();
        put_u8(&mut b, 5);
        put_u32(&mut b, 0x01020304);
        put_u16(&mut b, 0xBEEF);
        put_i32(&mut b, -1000);
        assert_eq!(b, vec![5, 0x04, 0x03, 0x02, 0x01, 0xEF, 0xBE, 0x18, 0xFC, 0xFF, 0xFF]);
    }
}
