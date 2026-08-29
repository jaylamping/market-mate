use ed25519_dalek::{Signature, Signer, SigningKey, VerifyingKey};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

pub const RECEIPT_DOMAIN: &str = "market-mate-checkpoint-receipt-v1";
pub const DIGEST_DOMAIN: &str = "market-mate-checkpoint-digest-v1";
pub const ALGORITHM: &str = "ed25519";

pub const PUBLIC_KEY_HEX_LEN: usize = 32;
pub const DIGEST_HEX_LEN: usize = 32;
pub const SIGNATURE_HEX_LEN: usize = 64;

pub const CHECKPOINT_TIME_LEN: usize = 27;

/// Converts days since 1970-01-01 to a civil UTC date (Howard Hinnant's algorithm).
fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let day_of_era = (z - era * 146_097) as u64;
    let year_of_era =
        (day_of_era - day_of_era / 1_460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let year = year_of_era as i64 + era * 400;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_index = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * month_index + 2) / 5 + 1;
    let month = if month_index < 10 {
        month_index + 3
    } else {
        month_index - 9
    };
    let year = if month <= 2 { year + 1 } else { year };
    (year, month as u32, day as u32)
}

pub fn format_epoch_micros(delta: std::time::Duration) -> String {
    let total_seconds = delta.as_secs();
    let micros = delta.subsec_micros();
    let days = (total_seconds / 86_400) as i64;
    let seconds_of_day = total_seconds % 86_400;
    let (year, month, day) = civil_from_days(days);
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}.{micros:06}Z",
        seconds_of_day / 3600,
        (seconds_of_day % 3600) / 60,
        seconds_of_day % 60
    )
}

pub fn utc_checkpoint_time_now() -> String {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock must be after the epoch");
    format_epoch_micros(now)
}

/// Converts a civil UTC date to days since 1970-01-01 (Howard Hinnant's algorithm).
fn days_from_civil(year: i64, month: u32, day: u32) -> i64 {
    let year = if month <= 2 { year - 1 } else { year };
    let era = if year >= 0 { year } else { year - 399 } / 400;
    let year_of_era = year - era * 400;
    let month_index = if month > 2 { month - 3 } else { month + 9 } as i64;
    let day_of_year = (153 * month_index + 2) / 5 + day as i64 - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    era * 146_097 + day_of_era - 719_468
}

/// Parses the fixed-width custody timestamp into a SystemTime.
///
/// The format is exactly `YYYY-MM-DDTHH:MM:SS.ffffffZ`; validity is checked by
/// re-formatting the parsed value, so impossible calendar dates fail closed.
pub fn parse_checkpoint_time(value: &str) -> Result<SystemTime, String> {
    let invalid = |detail: String| format!("checkpoint_time is invalid: {detail}");
    if value.len() != CHECKPOINT_TIME_LEN || !value.is_ascii() || !value.ends_with('Z') {
        return Err(invalid(format!(
            "expected {CHECKPOINT_TIME_LEN} ASCII characters ending in Z, got {}",
            value.len()
        )));
    }
    let bytes = value.as_bytes();
    if bytes[4] != b'-'
        || bytes[7] != b'-'
        || bytes[10] != b'T'
        || bytes[13] != b':'
        || bytes[16] != b':'
        || bytes[19] != b'.'
    {
        return Err(invalid("separators do not match the fixed format".into()));
    }
    let field = |slice: &str, name: &str| -> Result<i64, String> {
        slice
            .parse::<i64>()
            .map_err(|_| invalid(format!("{name} is not numeric")))
    };
    let year = field(&value[0..4], "year")?;
    let month = field(&value[5..7], "month")?;
    let day = field(&value[8..10], "day")?;
    let hour = field(&value[11..13], "hour")?;
    let minute = field(&value[14..16], "minute")?;
    let second = field(&value[17..19], "second")?;
    let micros = field(&value[20..26], "microseconds")?;
    if !(1..=12).contains(&month)
        || !(1..=31).contains(&day)
        || hour > 23
        || minute > 59
        || second > 59
        || !(0..1_000_000).contains(&micros)
    {
        return Err(invalid("a field is out of range".into()));
    }
    let seconds = days_from_civil(year, month as u32, day as u32) * 86_400
        + hour * 3_600
        + minute * 60
        + second;
    if seconds < 0 {
        return Err(invalid("timestamp is before the epoch".into()));
    }
    let delta = Duration::new(seconds as u64, (micros * 1_000) as u32);
    if format_epoch_micros(delta) != value {
        return Err(invalid("not a valid calendar date".into()));
    }
    Ok(UNIX_EPOCH + delta)
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CheckpointReceipt {
    pub checkpoint_index: i64,
    pub chain_position: i64,
    pub chain_digest: String,
    pub checkpoint_time: String,
    pub algorithm: String,
    pub public_key: String,
    pub signature: String,
}

pub fn is_lower_hex(value: &str, byte_len: usize) -> bool {
    value.len() == byte_len * 2
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

pub fn chain_digest(chain_position: i64, head_event_hash: &str) -> String {
    let digest =
        Sha256::digest(format!("{DIGEST_DOMAIN}|{chain_position}|{head_event_hash}").as_bytes());
    hex::encode(digest)
}

pub fn canonical_receipt_bytes(receipt: &CheckpointReceipt) -> Vec<u8> {
    format!(
        "{}|{}|{}|{}|{}",
        RECEIPT_DOMAIN,
        receipt.checkpoint_index,
        receipt.chain_position,
        receipt.chain_digest,
        receipt.checkpoint_time
    )
    .into_bytes()
}

pub fn validate_receipt_shape(receipt: &CheckpointReceipt) -> Result<(), String> {
    if receipt.checkpoint_index <= 0 {
        return Err(format!(
            "checkpoint_index must be positive, got {}",
            receipt.checkpoint_index
        ));
    }
    if receipt.chain_position <= 0 {
        return Err(format!(
            "chain_position must be positive, got {}",
            receipt.chain_position
        ));
    }
    if !is_lower_hex(&receipt.chain_digest, DIGEST_HEX_LEN) {
        return Err("chain_digest must be 64 lowercase hex characters".into());
    }
    if receipt.checkpoint_time.is_empty() {
        return Err("checkpoint_time must not be empty".into());
    }
    if receipt.algorithm != ALGORITHM {
        return Err(format!(
            "unsupported signature algorithm {}, expected {ALGORITHM}",
            receipt.algorithm
        ));
    }
    if !is_lower_hex(&receipt.public_key, PUBLIC_KEY_HEX_LEN) {
        return Err("public_key must be 64 lowercase hex characters".into());
    }
    if !is_lower_hex(&receipt.signature, SIGNATURE_HEX_LEN) {
        return Err("signature must be 128 lowercase hex characters".into());
    }
    Ok(())
}

pub fn verify_receipt_signature(receipt: &CheckpointReceipt) -> Result<(), String> {
    validate_receipt_shape(receipt)?;
    let key_bytes: [u8; 32] = hex::decode(&receipt.public_key)
        .ok()
        .and_then(|bytes| bytes.try_into().ok())
        .ok_or_else(|| "public_key is not valid hex of 32 bytes".to_string())?;
    let verifying_key = VerifyingKey::from_bytes(&key_bytes)
        .map_err(|error| format!("public_key is not a valid ed25519 key: {error}"))?;
    let signature_bytes: [u8; 64] = hex::decode(&receipt.signature)
        .ok()
        .and_then(|bytes| bytes.try_into().ok())
        .ok_or_else(|| "signature is not valid hex of 64 bytes".to_string())?;
    let signature = Signature::from_bytes(&signature_bytes);
    verifying_key
        .verify_strict(&canonical_receipt_bytes(receipt), &signature)
        .map_err(|error| format!("signature verification failed: {error}"))
}

pub fn sign_receipt(
    signing_key: &SigningKey,
    checkpoint_index: i64,
    chain_position: i64,
    chain_digest: String,
    checkpoint_time: String,
) -> CheckpointReceipt {
    let receipt = CheckpointReceipt {
        checkpoint_index,
        chain_position,
        chain_digest,
        checkpoint_time,
        algorithm: ALGORITHM.to_string(),
        public_key: hex::encode(signing_key.verifying_key().to_bytes()),
        signature: String::new(),
    };
    let signature = signing_key.sign(&canonical_receipt_bytes(&receipt));
    CheckpointReceipt {
        signature: hex::encode(signature.to_bytes()),
        ..receipt
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rand::rngs::OsRng;

    fn sample_receipt(signing_key: &SigningKey) -> CheckpointReceipt {
        sign_receipt(
            signing_key,
            1,
            3,
            chain_digest(3, "aa"),
            "2026-08-29T00:00:00.000000Z".into(),
        )
    }

    #[test]
    fn signed_receipt_verifies() {
        let signing_key = SigningKey::generate(&mut OsRng);
        let receipt = sample_receipt(&signing_key);
        assert!(verify_receipt_signature(&receipt).is_ok());
    }

    #[test]
    fn any_tampered_field_fails_verification() {
        let signing_key = SigningKey::generate(&mut OsRng);
        let mut receipt = sample_receipt(&signing_key);
        receipt.chain_digest = chain_digest(3, "bb");
        assert!(verify_receipt_signature(&receipt).is_err());

        let mut receipt = sample_receipt(&signing_key);
        receipt.chain_position += 1;
        assert!(verify_receipt_signature(&receipt).is_err());

        let mut receipt = sample_receipt(&signing_key);
        receipt.checkpoint_time = "2026-08-29T00:00:00.000001Z".into();
        assert!(verify_receipt_signature(&receipt).is_err());

        let mut receipt = sample_receipt(&signing_key);
        receipt.checkpoint_index += 1;
        assert!(verify_receipt_signature(&receipt).is_err());
    }

    #[test]
    fn signature_from_other_key_fails() {
        let signing_key = SigningKey::generate(&mut OsRng);
        let other_key = SigningKey::generate(&mut OsRng);
        let mut receipt = sample_receipt(&signing_key);
        receipt.public_key = hex::encode(other_key.verifying_key().to_bytes());
        assert!(verify_receipt_signature(&receipt).is_err());
    }

    #[test]
    fn malformed_receipts_fail_closed() {
        let signing_key = SigningKey::generate(&mut OsRng);
        let mut receipt = sample_receipt(&signing_key);
        receipt.chain_digest = "XYZ".into();
        assert!(verify_receipt_signature(&receipt).is_err());

        let mut receipt = sample_receipt(&signing_key);
        receipt.algorithm = "rsa".into();
        assert!(verify_receipt_signature(&receipt).is_err());

        let mut receipt = sample_receipt(&signing_key);
        receipt.checkpoint_index = 0;
        assert!(verify_receipt_signature(&receipt).is_err());
    }

    #[test]
    fn digest_is_position_bound() {
        assert_ne!(chain_digest(3, "aa"), chain_digest(4, "aa"));
        assert_eq!(
            chain_digest(3, "aa"),
            chain_digest(3, "aa"),
            "digest must be deterministic"
        );
        // Pinned test vector
        assert_eq!(
            chain_digest(
                1,
                "0000000000000000000000000000000000000000000000000000000000000000"
            ),
            "cf3459da8b9cab7583c4df5a4bbaddc9fac23f908a64bd2ad75eac739e1b5664"
        );
    }

    #[test]
    fn epoch_micros_format_matches_known_timestamps() {
        use std::time::Duration;
        assert_eq!(
            format_epoch_micros(Duration::from_secs(0)),
            "1970-01-01T00:00:00.000000Z"
        );
        assert_eq!(
            format_epoch_micros(Duration::from_secs(951_868_800)),
            "2000-03-01T00:00:00.000000Z"
        );
        assert_eq!(
            format_epoch_micros(
                Duration::from_secs(951_868_800 + 86_399) + Duration::from_micros(999_999)
            ),
            "2000-03-01T23:59:59.999999Z"
        );
        assert_eq!(
            format_epoch_micros(Duration::from_secs(1_788_000_000)),
            format_epoch_micros(Duration::from_secs(1_788_000_000)),
            "formatting must be deterministic"
        );
    }

    #[test]
    fn checkpoint_time_round_trips() {
        use std::time::Duration;
        for delta in [
            Duration::from_secs(0),
            Duration::from_secs(951_868_800) + Duration::from_micros(1),
            Duration::new(1_709_164_800, 0) + Duration::from_micros(123_456),
        ] {
            let formatted = format_epoch_micros(delta);
            let parsed = parse_checkpoint_time(&formatted).expect("formatted time must parse");
            assert_eq!(
                parsed.duration_since(UNIX_EPOCH).unwrap(),
                delta,
                "round trip failed for {formatted}"
            );
        }
        let leap_day =
            parse_checkpoint_time("2024-02-29T12:00:00.000000Z").expect("leap day must parse");
        assert_eq!(
            format_epoch_micros(leap_day.duration_since(UNIX_EPOCH).unwrap()),
            "2024-02-29T12:00:00.000000Z"
        );
    }

    #[test]
    fn checkpoint_time_rejects_invalid_values() {
        for bad in [
            "2026-02-30T00:00:00.000000Z",  // impossible calendar date
            "2026-13-01T00:00:00.000000Z",  // month out of range
            "2026-01-32T00:00:00.000000Z",  // day out of range
            "2026-01-01T24:00:00.000000Z",  // hour out of range
            "2026-01-01T00:60:00.000000Z",  // minute out of range
            "2026-01-01T00:00:60.000000Z",  // second out of range
            "2026-01-01T00:00:00.0000000Z", // wrong width
            "2026/01/01T00:00:00.000000Z",  // wrong separator
            "2026-01-01 00:00:00.000000Z",  // wrong time separator
            "2026-01-01T00:00:00.000000",   // missing zone
            "2026-01-01T00:00:00.00000éZ",  // multi-byte non-ascii boundary
            "",                             // empty
        ] {
            assert!(
                parse_checkpoint_time(bad).is_err(),
                "{bad} should not parse"
            );
        }
        assert!(parse_checkpoint_time("1969-12-31T23:59:59.999999Z").is_err());
    }
}
