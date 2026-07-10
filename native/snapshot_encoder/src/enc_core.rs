//! EncoderCore: pure-Rust snapshot delta encoder + native baseline history (ADR-0003).
//! Byte-identical contract with shared/net/snapshot.gd — see the parity invariants in
//! docs/superpowers/specs/2026-07-10-native-snapshot-encoder-design.md §4.
//! INVARIANT: nothing hash-ordered is ever iterated into wire output — ordered Vecs only.

use crate::wire::*;
use rustc_hash::{FxHashMap, FxHashSet};
use std::collections::BTreeMap;
use std::sync::Arc;

pub const PAWN_STRIDE: usize = 10;
pub const VEH_STRIDE: usize = 7;
pub const MAX_HISTORY: i64 = 32; // server_main.gd MAX_HISTORY

const FLAG_ENTER: u8 = 1;
const FLAG_LEAVE: u8 = 2;
const FLAG_CHANGED: u8 = 4;
const F_ALL: u8 = 255;
// pawn lane i diffs into mask bit (1 << i) for lanes 0..8 (px,py,pz,yaw,pitch,state,health,squad)
const F_YAW: u8 = 8;
const F_PITCH: u8 = 16;
const F_STATE: u8 = 32;
const F_HEALTH: u8 = 64;
const F_SQUAD: u8 = 128;
const VF_HEADING: u8 = 8;
const VF_TURRET: u8 = 16;
const VF_HP: u8 = 32;
const VF_SEATS: u8 = 64;
const VF_TYPE: u8 = 128;

pub struct TickData {
    pub tick: u32,
    pub ids: Vec<i32>,
    pub fields: Vec<i32>,
    pub row: FxHashMap<i32, usize>,
    pub vids: Vec<i32>,
    pub vfields: Vec<i32>,
    pub vseats: Vec<i32>,
    pub vseat_off: Vec<i32>,
    pub vrow: FxHashMap<i32, usize>,
}

struct HistoryRec {
    tick: Arc<TickData>,
    sent_ids: Vec<i32>,
    sent_set: FxHashSet<i32>,
    sent_vids: Vec<i32>,
    sent_vset: FxHashSet<i32>,
}

pub struct EncoderCore {
    msg_id: u8,
    cur: Option<Arc<TickData>>,
    hist: FxHashMap<i32, BTreeMap<i64, HistoryRec>>,
}

impl EncoderCore {
    pub fn new() -> Self {
        Self { msg_id: 0, cur: None, hist: FxHashMap::default() }
    }

    pub fn set_msg_id(&mut self, id: u8) {
        self.msg_id = id;
    }

    pub fn begin_tick(&mut self, tick: u32, ids: &[i32], fields: &[i32], vids: &[i32],
            vfields: &[i32], vseats: &[i32], vseat_off: &[i32]) -> Result<(), String> {
        if fields.len() != ids.len() * PAWN_STRIDE {
            return Err(format!("pawn columns ragged: {} ids vs {} fields", ids.len(), fields.len()));
        }
        if vfields.len() != vids.len() * VEH_STRIDE || vseat_off.len() != vids.len() + 1 {
            return Err("vehicle columns ragged".into());
        }
        if *vseat_off.last().unwrap_or(&0) as usize != vseats.len() {
            return Err("vseat_off does not close vseats".into());
        }
        let mut row = FxHashMap::default();
        for (i, &id) in ids.iter().enumerate() {
            row.insert(id, i);
        }
        let mut vrow = FxHashMap::default();
        for (i, &vid) in vids.iter().enumerate() {
            vrow.insert(vid, i);
        }
        self.cur = Some(Arc::new(TickData {
            tick,
            ids: ids.to_vec(),
            fields: fields.to_vec(),
            row,
            vids: vids.to_vec(),
            vfields: vfields.to_vec(),
            vseats: vseats.to_vec(),
            vseat_off: vseat_off.to_vec(),
            vrow,
        }));
        Ok(())
    }

    /// Native interest + enemy cull (ADR-0003 A.5): membership from the CURRENT tick columns —
    /// exact 3D distance on the quantized mm positions, `d2 <= radius_mm^2` (matches the
    /// GDScript grid's inclusive exact-distance filter, on fresher positions). Over
    /// `max_entities`, keep self + every teammate + the nearest `max_enemies` enemies
    /// (ties broken by ascending id, mirroring the reference `[d2, id]` lexicographic sort).
    /// Record order is canonical column (world-insertion) order — decode is order-independent;
    /// parity for this layer is verified at the decoded-view level (see native_interest_view_test).
    pub fn encode_for_auto(&mut self, client: i32, self_id: i32, seq: i64, want_baseline_seq: i64,
            last_input_tick: u32, radius_mm: i64, max_entities: usize, max_enemies: usize)
            -> Result<Vec<u8>, String> {
        let cur = self.cur.clone().ok_or("encode_for_auto before begin_tick")?;
        let srow = *cur.row.get(&self_id)
            .ok_or_else(|| format!("self id {self_id} not in tick columns"))?;
        let sf = &cur.fields[srow * PAWN_STRIDE..srow * PAWN_STRIDE + PAWN_STRIDE];
        let (sx, sy, sz) = (sf[0] as i64, sf[1] as i64, sf[2] as i64);
        let steam = (sf[5] >> 4) & 1;
        let r2 = radius_mm * radius_mm;

        let mut members: Vec<i32> = Vec::with_capacity(cur.ids.len().min(max_entities * 2));
        let mut d2s: Vec<i64> = Vec::with_capacity(members.capacity());
        for (i, &id) in cur.ids.iter().enumerate() {
            let f = &cur.fields[i * PAWN_STRIDE..i * PAWN_STRIDE + PAWN_STRIDE];
            let (dx, dy, dz) = (f[0] as i64 - sx, f[1] as i64 - sy, f[2] as i64 - sz);
            let d2 = dx * dx + dy * dy + dz * dz;
            if d2 <= r2 {
                members.push(id);
                d2s.push(d2);
            }
        }
        if members.len() > max_entities {
            // Enemy relevance cull: self + all teammates always; nearest max_enemies enemies.
            let mut enemies: Vec<(i64, i32)> = Vec::new();
            let mut kept: FxHashSet<i32> = FxHashSet::default();
            kept.insert(self_id);
            for (k, &id) in members.iter().enumerate() {
                if id == self_id {
                    continue;
                }
                let row = cur.row[&id];
                let team = (cur.fields[row * PAWN_STRIDE + 5] >> 4) & 1;
                if team == steam {
                    kept.insert(id);
                } else {
                    enemies.push((d2s[k], id));
                }
            }
            enemies.sort_unstable();
            for &(_, id) in enemies.iter().take(max_enemies) {
                kept.insert(id);
            }
            members.retain(|id| kept.contains(id));
        }

        let mut vmembers: Vec<i32> = Vec::new();
        for (i, &vid) in cur.vids.iter().enumerate() {
            let f = &cur.vfields[i * VEH_STRIDE..i * VEH_STRIDE + VEH_STRIDE];
            let (dx, dy, dz) = (f[0] as i64 - sx, f[1] as i64 - sy, f[2] as i64 - sz);
            if dx * dx + dy * dy + dz * dz <= r2 {
                vmembers.push(vid);
            }
        }
        self.encode_with(cur, client, seq, want_baseline_seq, last_input_tick, &members, &vmembers)
    }

    pub fn encode_for(&mut self, client: i32, seq: i64, want_baseline_seq: i64,
            last_input_tick: u32, interest_ids: &[i32], interest_vids: &[i32])
            -> Result<Vec<u8>, String> {
        let cur = self.cur.clone().ok_or("encode_for before begin_tick")?;
        self.encode_with(cur, client, seq, want_baseline_seq, last_input_tick, interest_ids, interest_vids)
    }

    fn encode_with(&mut self, cur: Arc<TickData>, client: i32, seq: i64, want_baseline_seq: i64,
            last_input_tick: u32, interest_ids: &[i32], interest_vids: &[i32])
            -> Result<Vec<u8>, String> {
        let baseline = self.hist.get(&client).and_then(|h| h.get(&want_baseline_seq));
        let baseline_seq: u32 = if baseline.is_some() { want_baseline_seq as u32 } else { 0 };

        let interest_set: FxHashSet<i32> = interest_ids.iter().copied().collect();
        let mut recs: Vec<u8> = Vec::with_capacity(interest_ids.len() * 24);
        let mut count: u32 = 0;
        for &id in interest_ids {
            let crow = *cur.row.get(&id)
                .ok_or_else(|| format!("interest id {id} not in tick columns"))?;
            let cf = &cur.fields[crow * PAWN_STRIDE..crow * PAWN_STRIDE + PAWN_STRIDE];
            let base_fields = baseline.and_then(|r| {
                if !r.sent_set.contains(&id) {
                    return None;
                }
                let brow = *r.tick.row.get(&id)?;
                Some(&r.tick.fields[brow * PAWN_STRIDE..brow * PAWN_STRIDE + PAWN_STRIDE])
            });
            match base_fields {
                Some(bf) => {
                    let mut mask: u8 = 0;
                    for lane in 0..8 {
                        if cf[lane] != bf[lane] {
                            mask |= 1 << lane;
                        }
                    }
                    if mask == 0 {
                        continue;
                    }
                    count += 1;
                    put_u32(&mut recs, id as u32);
                    put_u8(&mut recs, FLAG_CHANGED);
                    put_pawn_fields(&mut recs, cf, mask);
                }
                None => {
                    count += 1;
                    put_u32(&mut recs, id as u32);
                    put_u8(&mut recs, FLAG_ENTER);
                    put_pawn_fields(&mut recs, cf, F_ALL);
                    put_u8(&mut recs, (cf[8] & 3) as u8);
                    put_u8(&mut recs, (cf[9] & 0xFF) as u8);
                }
            }
        }
        if let Some(r) = baseline {
            for &id in &r.sent_ids {
                if !interest_set.contains(&id) {
                    count += 1;
                    put_u32(&mut recs, id as u32);
                    put_u8(&mut recs, FLAG_LEAVE);
                }
            }
        }

        let (vrecs, vcount) = encode_vehicles(&cur, baseline, interest_vids)?;

        let mut buf: Vec<u8> = Vec::with_capacity(21 + recs.len() + vrecs.len());
        put_u8(&mut buf, self.msg_id);
        put_u32(&mut buf, cur.tick);
        put_u32(&mut buf, seq as u32);
        put_u32(&mut buf, baseline_seq);
        put_u32(&mut buf, last_input_tick);
        put_u16(&mut buf, count as u16);
        buf.extend_from_slice(&recs);
        put_u16(&mut buf, vcount as u16);
        buf.extend_from_slice(&vrecs);

        // history: full interest map (not just emitted records), mirroring c["history"][seq] = current
        let rec = HistoryRec {
            tick: cur.clone(),
            sent_ids: interest_ids.to_vec(),
            sent_set: interest_set,
            sent_vids: interest_vids.to_vec(),
            sent_vset: interest_vids.iter().copied().collect(),
        };
        let h = self.hist.entry(client).or_default();
        h.insert(seq, rec);
        let cutoff = seq - MAX_HISTORY;
        h.retain(|&s, _| s >= cutoff);
        Ok(buf)
    }

    pub fn on_ack(&mut self, client: i32, ack: i64) {
        if let Some(h) = self.hist.get_mut(&client) {
            h.retain(|&s, _| s >= ack);
        }
    }

    pub fn remove_client(&mut self, client: i32) {
        self.hist.remove(&client);
    }

    pub fn drop_entity_from_baselines(&mut self, id: i32) {
        for h in self.hist.values_mut() {
            for rec in h.values_mut() {
                if rec.sent_set.remove(&id) {
                    rec.sent_ids.retain(|&x| x != id);
                }
            }
        }
    }

    pub fn reset(&mut self) {
        self.hist.clear();
        self.cur = None;
    }

    pub fn history_len(&self, client: i32) -> usize {
        self.hist.get(&client).map_or(0, |h| h.len())
    }

    pub fn live_tick_count(&self) -> usize {
        let mut ptrs: FxHashSet<*const TickData> = FxHashSet::default();
        if let Some(c) = &self.cur {
            ptrs.insert(Arc::as_ptr(c));
        }
        for h in self.hist.values() {
            for r in h.values() {
                ptrs.insert(Arc::as_ptr(&r.tick));
            }
        }
        ptrs.len()
    }
}

fn encode_vehicles(cur: &TickData, baseline: Option<&HistoryRec>,
        interest_vids: &[i32]) -> Result<(Vec<u8>, u32), String> {
    let vset: FxHashSet<i32> = interest_vids.iter().copied().collect();
    let mut recs = Vec::new();
    let mut count: u32 = 0;
    for &vid in interest_vids {
        let crow = *cur.vrow.get(&vid)
            .ok_or_else(|| format!("interest vid {vid} not in tick columns"))?;
        let cf = &cur.vfields[crow * VEH_STRIDE..crow * VEH_STRIDE + VEH_STRIDE];
        let cseats = &cur.vseats[cur.vseat_off[crow] as usize..cur.vseat_off[crow + 1] as usize];
        let base = baseline.and_then(|r| {
            if !r.sent_vset.contains(&vid) {
                return None;
            }
            let brow = *r.tick.vrow.get(&vid)?;
            let bf = &r.tick.vfields[brow * VEH_STRIDE..brow * VEH_STRIDE + VEH_STRIDE];
            let bs = &r.tick.vseats[r.tick.vseat_off[brow] as usize..r.tick.vseat_off[brow + 1] as usize];
            Some((bf, bs))
        });
        match base {
            Some((bf, bs)) => {
                let mut mask: u8 = 0;
                for lane in 0..5 {
                    if cf[lane] != bf[lane] {
                        mask |= 1 << lane;
                    }
                }
                if cf[5] != bf[5] {
                    mask |= VF_HP;
                }
                if cseats != bs {
                    mask |= VF_SEATS;
                }
                if cf[6] != bf[6] {
                    mask |= VF_TYPE;
                }
                if mask == 0 {
                    continue;
                }
                count += 1;
                put_u32(&mut recs, vid as u32);
                put_u8(&mut recs, FLAG_CHANGED);
                put_veh_fields(&mut recs, cf, cseats, mask);
            }
            None => {
                count += 1;
                put_u32(&mut recs, vid as u32);
                put_u8(&mut recs, FLAG_ENTER);
                put_veh_fields(&mut recs, cf, cseats, F_ALL);
            }
        }
    }
    if let Some(r) = baseline {
        for &vid in &r.sent_vids {
            if !vset.contains(&vid) {
                count += 1;
                put_u32(&mut recs, vid as u32);
                put_u8(&mut recs, FLAG_LEAVE);
            }
        }
    }
    Ok((recs, count))
}

fn put_pawn_fields(b: &mut Vec<u8>, f: &[i32], mask: u8) {
    put_u8(b, mask);
    if mask & 1 != 0 { put_i32(b, f[0]); }
    if mask & 2 != 0 { put_i32(b, f[1]); }
    if mask & 4 != 0 { put_i32(b, f[2]); }
    if mask & F_YAW != 0 { put_u16(b, f[3] as u16); }
    if mask & F_PITCH != 0 { put_u16(b, f[4] as u16); }
    if mask & F_STATE != 0 { put_u8(b, f[5] as u8); }
    if mask & F_HEALTH != 0 { put_u8(b, f[6].clamp(0, 255) as u8); }
    if mask & F_SQUAD != 0 { put_u8(b, (f[7] & 0xFF) as u8); }
}

fn put_veh_fields(b: &mut Vec<u8>, f: &[i32], seats: &[i32], mask: u8) {
    put_u8(b, mask);
    if mask & 1 != 0 { put_i32(b, f[0]); }
    if mask & 2 != 0 { put_i32(b, f[1]); }
    if mask & 4 != 0 { put_i32(b, f[2]); }
    if mask & VF_HEADING != 0 { put_u16(b, f[3] as u16); }
    if mask & VF_TURRET != 0 { put_u16(b, f[4] as u16); }
    if mask & VF_HP != 0 { put_u16(b, f[5].clamp(0, 65535) as u16); }
    if mask & VF_SEATS != 0 {
        put_u8(b, seats.len() as u8);
        for &s in seats {
            put_u32(b, s as u32);
        }
    }
    if mask & VF_TYPE != 0 { put_u8(b, (f[6] & 0xFF) as u8); }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pawn(id: i32, px: i32, health: i32) -> (i32, [i32; PAWN_STRIDE]) {
        (id, [px, 2000, 3000, 100, 200, 0b100001, health, 1, 2, 4])
    }

    fn core_with_tick(pawns: &[(i32, [i32; PAWN_STRIDE])], tick: u32) -> EncoderCore {
        let mut c = EncoderCore::new();
        c.set_msg_id(5);
        let ids: Vec<i32> = pawns.iter().map(|p| p.0).collect();
        let fields: Vec<i32> = pawns.iter().flat_map(|p| p.1).collect();
        c.begin_tick(tick, &ids, &fields, &[], &[], &[], &[0]).unwrap();
        c
    }

    #[test]
    fn keyframe_all_enter_with_extras() {
        let mut c = core_with_tick(&[pawn(1, 1000, 90), pawn(2, -500, 300)], 7);
        let buf = c.encode_for(42, 1, 0, 99, &[1, 2], &[]).unwrap();
        // header: msg,tick,seq,baseline_seq(0=keyframe),last_input_tick,count=2
        assert_eq!(buf[0], 5);
        assert_eq!(u32::from_le_bytes(buf[1..5].try_into().unwrap()), 7);
        assert_eq!(u32::from_le_bytes(buf[5..9].try_into().unwrap()), 1);
        assert_eq!(u32::from_le_bytes(buf[9..13].try_into().unwrap()), 0);
        assert_eq!(u32::from_le_bytes(buf[13..17].try_into().unwrap()), 99);
        assert_eq!(u16::from_le_bytes(buf[17..19].try_into().unwrap()), 2);
        // rec 1: id=1 ENTER mask=255 → id(4)+flags(1)+mask(1) + 3*i32 + 2*u16 + 3*u8 + armor + weapon
        assert_eq!(u32::from_le_bytes(buf[19..23].try_into().unwrap()), 1);
        assert_eq!(buf[23], FLAG_ENTER);
        assert_eq!(buf[24], F_ALL);
        let rec1_end = 25 + 12 + 4 + 3 + 2;
        assert_eq!(buf[rec1_end - 2], 2 & 3); // armor
        assert_eq!(buf[rec1_end - 1], 4); // weapon
        // rec 2 health 300 must clamp to 255 at write
        let h2 = rec1_end + 4 + 1 + 1 + 12 + 4 + 1; // through pos+angles+state byte
        assert_eq!(buf[h2], 255);
        // trailing vcount == 0
        let n = buf.len();
        assert_eq!(u16::from_le_bytes(buf[n - 2..].try_into().unwrap()), 0);
    }

    #[test]
    fn delta_changed_leave_and_clamped_write() {
        let mut c = core_with_tick(&[pawn(1, 1000, 90), pawn(2, 0, 50)], 7);
        c.encode_for(42, 1, 0, 0, &[1, 2], &[]).unwrap();
        // next tick: pawn 1 health 90 -> 300 (raw diff fires, write clamps), pawn 3 enters, pawn 2 leaves
        let p1 = pawn(1, 1000, 300);
        let p3 = pawn(3, 5, 5);
        let ids = vec![1, 3];
        let fields: Vec<i32> = [p1.1, p3.1].concat();
        c.begin_tick(8, &ids, &fields, &[], &[], &[], &[0]).unwrap();
        let buf = c.encode_for(42, 2, 1, 0, &[1, 3], &[]).unwrap();
        assert_eq!(u16::from_le_bytes(buf[17..19].try_into().unwrap()), 3);
        assert_eq!(buf[23], FLAG_CHANGED);
        assert_eq!(buf[24], F_HEALTH);
        assert_eq!(buf[25], 255); // clamped write of raw 300
        // rec 2: id=3 ENTER; rec 3: id=2 LEAVE with no mask byte
        let leave_at = 26 + (4 + 1 + 1 + 12 + 4 + 3 + 2);
        assert_eq!(u32::from_le_bytes(buf[leave_at..leave_at + 4].try_into().unwrap()), 2);
        assert_eq!(buf[leave_at + 4], FLAG_LEAVE);
    }

    #[test]
    fn raw_equal_over_clamp_boundary_emits_no_record() {
        // health 300 → 300 must NOT diff (raw compare), even though both clamp to 255.
        let mut c = core_with_tick(&[pawn(1, 1000, 300)], 1);
        c.encode_for(9, 1, 0, 0, &[1], &[]).unwrap();
        let (id, f) = pawn(1, 1000, 300);
        c.begin_tick(2, &[id], &f, &[], &[], &[], &[0]).unwrap();
        let buf = c.encode_for(9, 2, 1, 0, &[1], &[]).unwrap();
        assert_eq!(buf.len(), 21); // header 19 + vcount 2 — zero records
    }

    #[test]
    fn record_order_is_interest_order_not_sorted() {
        let mut c = core_with_tick(&[pawn(1, 0, 1), pawn(2, 0, 1), pawn(9, 0, 1)], 1);
        let buf = c.encode_for(9, 1, 0, 0, &[9, 1, 2], &[]).unwrap();
        assert_eq!(u32::from_le_bytes(buf[19..23].try_into().unwrap()), 9);
    }

    fn veh(vid: i32, px: i32, hp: i32, seats: &[i32]) -> (i32, [i32; VEH_STRIDE], Vec<i32>) {
        (vid, [px, 0, 0, 50, 60, hp, 1], seats.to_vec())
    }

    fn begin_with_vehicles(c: &mut EncoderCore, tick: u32, vehs: &[(i32, [i32; VEH_STRIDE], Vec<i32>)]) {
        let vids: Vec<i32> = vehs.iter().map(|v| v.0).collect();
        let vfields: Vec<i32> = vehs.iter().flat_map(|v| v.1).collect();
        let mut vseats = Vec::new();
        let mut voff = vec![0i32];
        for v in vehs {
            vseats.extend_from_slice(&v.2);
            voff.push(vseats.len() as i32);
        }
        c.begin_tick(tick, &[], &[], &vids, &vfields, &vseats, &voff).unwrap();
    }

    #[test]
    fn vehicle_enter_seats_and_leave() {
        let mut c = EncoderCore::new();
        c.set_msg_id(5);
        begin_with_vehicles(&mut c, 1, &[veh(1000, 5, 70000, &[7, 9])]);
        let buf = c.encode_for(1, 1, 0, 0, &[], &[1000]).unwrap();
        // count u16 at 17..19 = 0, vcount at 19..21 = 1
        assert_eq!(u16::from_le_bytes(buf[17..19].try_into().unwrap()), 0);
        assert_eq!(u16::from_le_bytes(buf[19..21].try_into().unwrap()), 1);
        assert_eq!(u32::from_le_bytes(buf[21..25].try_into().unwrap()), 1000);
        assert_eq!(buf[25], FLAG_ENTER);
        assert_eq!(buf[26], 255);
        // fields: 12B pos, 2+2 angles, hp u16 clamped(70000→65535), seats u8 2 + 2*u32, type u8
        let hp = u16::from_le_bytes(buf[27 + 12 + 4..27 + 12 + 6].try_into().unwrap());
        assert_eq!(hp, 65535);
        assert_eq!(buf[27 + 12 + 6], 2); // seat count
        // vehicle leaves next tick
        begin_with_vehicles(&mut c, 2, &[]);
        let buf2 = c.encode_for(1, 2, 1, 0, &[], &[]).unwrap();
        assert_eq!(u16::from_le_bytes(buf2[19..21].try_into().unwrap()), 1);
        assert_eq!(buf2[25], FLAG_LEAVE);
    }

    #[test]
    fn vehicle_seat_change_diffs_as_list() {
        let mut c = EncoderCore::new();
        c.set_msg_id(5);
        begin_with_vehicles(&mut c, 1, &[veh(1000, 5, 100, &[7])]);
        c.encode_for(1, 1, 0, 0, &[], &[1000]).unwrap();
        begin_with_vehicles(&mut c, 2, &[veh(1000, 5, 100, &[7, 8])]);
        let buf = c.encode_for(1, 2, 1, 0, &[], &[1000]).unwrap();
        assert_eq!(buf[25], FLAG_CHANGED);
        assert_eq!(buf[26], VF_SEATS);
        assert_eq!(buf[27], 2); // new seat count
    }

    #[test]
    fn max_history_prune_and_ack_prune() {
        let mut c = core_with_tick(&[pawn(1, 0, 1)], 1);
        for s in 1..=40i64 {
            c.encode_for(9, s, 0, 0, &[1], &[]).unwrap();
        }
        // GDScript prunes `s < seq - MAX_HISTORY`, so the cutoff seq itself survives:
        // after inserting seq 40, seqs 8..=40 remain = 33 entries (MAX_HISTORY + 1).
        assert_eq!(c.history_len(9), MAX_HISTORY as usize + 1);
        c.on_ack(9, 38);
        assert_eq!(c.history_len(9), 3); // 38,39,40
        c.remove_client(9);
        assert_eq!(c.history_len(9), 0);
    }

    #[test]
    fn aged_out_baseline_falls_back_to_keyframe() {
        let mut c = core_with_tick(&[pawn(1, 0, 1)], 1);
        c.encode_for(9, 1, 0, 0, &[1], &[]).unwrap();
        c.on_ack(9, 2); // prunes seq 1
        let buf = c.encode_for(9, 2, 1, 0, &[1], &[]).unwrap(); // wants seq1: gone → keyframe
        assert_eq!(u32::from_le_bytes(buf[9..13].try_into().unwrap()), 0);
        assert_eq!(buf[23], FLAG_ENTER);
    }

    #[test]
    fn drop_entity_forces_reenter_without_leave() {
        let mut c = core_with_tick(&[pawn(1, 0, 1), pawn(2, 0, 1)], 1);
        c.encode_for(9, 1, 0, 0, &[1, 2], &[]).unwrap();
        c.drop_entity_from_baselines(2);
        // same interest, no field changes: pawn 2 must ENTER again; pawn 1 no record; NO LEAVE for 2
        let buf = c.encode_for(9, 2, 1, 0, &[1, 2], &[]).unwrap();
        assert_eq!(u16::from_le_bytes(buf[17..19].try_into().unwrap()), 1);
        assert_eq!(u32::from_le_bytes(buf[19..23].try_into().unwrap()), 2);
        assert_eq!(buf[23], FLAG_ENTER);
    }

    // --- encode_for_auto (native interest + cull) ---

    fn pawn_at(id: i32, x: i32, z: i32, team: i32, health: i32) -> (i32, [i32; PAWN_STRIDE]) {
        // q_state bit4 = team
        (id, [x, 0, z, 0, 0, (team & 1) << 4, health, 0, 0, 0])
    }

    fn decode_record_ids(buf: &[u8]) -> Vec<u32> {
        // walk pawn records of an ENTER-only keyframe (mask always 255 → fixed size)
        let count = u16::from_le_bytes(buf[17..19].try_into().unwrap()) as usize;
        let mut ids = Vec::new();
        let mut off = 19;
        for _ in 0..count {
            ids.push(u32::from_le_bytes(buf[off..off + 4].try_into().unwrap()));
            off += 4 + 1 + 1 + 12 + 4 + 3 + 2; // id flags mask pos angles state/hp/squad armor+weapon
        }
        ids
    }

    #[test]
    fn auto_membership_is_inclusive_exact_distance() {
        // radius 10m = 10000mm; entity at exactly 10000 is IN (<=), at 10001 is OUT.
        let mut c = core_with_tick(&[
            pawn_at(1, 0, 0, 0, 1),       // self
            pawn_at(2, 10000, 0, 0, 1),   // exactly on the boundary
            pawn_at(3, 10001, 0, 0, 1),   // just outside
        ], 1);
        let buf = c.encode_for_auto(9, 1, 1, 0, 0, 10000, 32, 8).unwrap();
        assert_eq!(decode_record_ids(&buf), vec![1, 2]);
    }

    #[test]
    fn auto_cull_keeps_self_teammates_and_nearest_enemies_tie_by_id() {
        // max_entities 4, max_enemies 2: self(t0) + 2 teammates + 4 enemies in range.
        // enemies 20 & 21 tie on distance -> lower id wins the last slot.
        let mut c = core_with_tick(&[
            pawn_at(1, 0, 0, 0, 1),        // self
            pawn_at(2, 500, 0, 0, 1),      // teammate (always kept)
            pawn_at(3, 900, 0, 0, 1),      // teammate (always kept)
            pawn_at(10, 100, 0, 1, 1),     // enemy, nearest
            pawn_at(21, 200, 0, 1, 1),     // enemy, tied with 20
            pawn_at(20, 200, 0, 1, 1),     // enemy, tied with 21 (lower id -> kept)
            pawn_at(30, 300, 0, 1, 1),     // enemy, farthest
        ], 1);
        let buf = c.encode_for_auto(9, 1, 1, 0, 0, 250000, 4, 2).unwrap();
        // canonical column order, membership = {1,2,3} + enemies {10,20}
        assert_eq!(decode_record_ids(&buf), vec![1, 2, 3, 10, 20]);
    }

    #[test]
    fn auto_under_cap_keeps_everyone_in_range() {
        let mut c = core_with_tick(&[
            pawn_at(1, 0, 0, 0, 1),
            pawn_at(10, 100, 0, 1, 1),
            pawn_at(11, 999999, 0, 1, 1), // far outside 250m
        ], 1);
        let buf = c.encode_for_auto(9, 1, 1, 0, 0, 250000, 32, 8).unwrap();
        assert_eq!(decode_record_ids(&buf), vec![1, 10]);
    }

    #[test]
    fn auto_history_supports_delta_and_leave() {
        let mut c = core_with_tick(&[pawn_at(1, 0, 0, 0, 1), pawn_at(2, 5000, 0, 0, 1)], 1);
        c.encode_for_auto(9, 1, 1, 0, 0, 250000, 32, 8).unwrap();
        // entity 2 walks out of range -> LEAVE via the auto path's stored history
        let pawns = [pawn_at(1, 0, 0, 0, 1), pawn_at(2, 900000, 0, 0, 1)];
        let ids: Vec<i32> = pawns.iter().map(|p| p.0).collect();
        let fields: Vec<i32> = pawns.iter().flat_map(|p| p.1).collect();
        c.begin_tick(2, &ids, &fields, &[], &[], &[], &[0]).unwrap();
        let buf = c.encode_for_auto(9, 1, 2, 1, 0, 250000, 32, 8).unwrap();
        // 1 unchanged (no record), 2 -> LEAVE; count == 1
        assert_eq!(u16::from_le_bytes(buf[17..19].try_into().unwrap()), 1);
        assert_eq!(u32::from_le_bytes(buf[19..23].try_into().unwrap()), 2);
        assert_eq!(buf[23], FLAG_LEAVE);
    }

    #[test]
    fn auto_unknown_self_errors() {
        let mut c = core_with_tick(&[pawn_at(1, 0, 0, 0, 1)], 1);
        assert!(c.encode_for_auto(9, 77, 1, 0, 0, 250000, 32, 8).is_err());
    }

    #[test]
    fn tick_data_evicted_when_unreferenced() {
        let mut c = core_with_tick(&[pawn(1, 0, 1)], 1);
        c.encode_for(9, 1, 0, 0, &[1], &[]).unwrap();
        for t in 2..=80u32 {
            let (id, f) = pawn(1, t as i32, 1);
            c.begin_tick(t, &[id], &f, &[], &[], &[], &[0]).unwrap();
            c.encode_for(9, t as i64, t as i64 - 1, 0, &[1], &[]).unwrap();
        }
        // MAX_HISTORY(32) recs + cur → bounded distinct ticks alive
        assert!(c.live_tick_count() <= MAX_HISTORY as usize + 1);
    }
}
