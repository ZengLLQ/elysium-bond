use starknet::ContractAddress;

#[derive(Copy, Drop, Serde, starknet::Store)]
pub struct Bond {
    pub bond_id: u64,
    pub issuer: ContractAddress,
    pub holder: ContractAddress,
    pub principal_collateral: u256,
    pub face_value: u256,
    pub discount_rate_bps: u64,
    pub issue_timestamp: u64,
    pub maturity_timestamp: u64,
    pub is_redeemed: bool,
    pub is_defaulted: bool,
}

#[derive(Copy, Drop, Serde, starknet::Store)]
pub struct TrancheState {
    pub senior_principal: u256,
    pub senior_yield_owed: u256,
    pub junior_buffer: u256,
    pub total_reserves: u256,
    pub min_junior_ratio_bps: u64,
}
