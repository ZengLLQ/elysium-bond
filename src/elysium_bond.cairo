#[starknet::contract]
pub mod ElysiumBondContract {
    use starknet::{ContractAddress, get_block_timestamp, get_caller_address};
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };
    use crate::types::{Bond, TrancheState};
    use crate::math::{
        calculate_discounted_issuance_price, calculate_early_redemption_value,
        calculate_junior_loss_absorption,
    };

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        BondIssued: BondIssued,
        BondRedeemed: BondRedeemed,
        JuniorDepositAdded: JuniorDepositAdded,
        LossAbsorbed: LossAbsorbed,
    }

    #[derive(Drop, starknet::Event)]
    pub struct BondIssued {
        #[key]
        pub bond_id: u64,
        #[key]
        pub issuer: ContractAddress,
        #[key]
        pub holder: ContractAddress,
        pub face_value: u256,
        pub issuance_price: u256,
        pub maturity_timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct BondRedeemed {
        #[key]
        pub bond_id: u64,
        #[key]
        pub holder: ContractAddress,
        pub payout_amount: u256,
        pub is_early: bool,
    }

    #[derive(Drop, starknet::Event)]
    pub struct JuniorDepositAdded {
        #[key]
        pub depositor: ContractAddress,
        pub amount: u256,
        pub new_junior_buffer: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct LossAbsorbed {
        pub loss_amount: u256,
        pub junior_absorbed: u256,
        pub senior_haircut: u256,
    }

    #[storage]
    struct Storage {
        pub admin: ContractAddress,
        pub bond_count: u64,
        pub bonds: Map<u64, Bond>,
        pub tranche: TrancheState,
        pub paused: bool,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        admin: ContractAddress,
        initial_junior_buffer: u256,
        min_junior_ratio_bps: u64,
    ) {
        self.admin.write(admin);
        self.bond_count.write(0);
        self.paused.write(false);
        let tranche = TrancheState {
            senior_principal: 0,
            senior_yield_owed: 0,
            junior_buffer: initial_junior_buffer,
            total_reserves: initial_junior_buffer,
            min_junior_ratio_bps,
        };
        self.tranche.write(tranche);
    }

    #[generate_trait]
    pub impl ElysiumBondImpl of IElysiumBond {
        fn issue_bond(
            ref self: ContractState,
            holder: ContractAddress,
            face_value: u256,
            discount_rate_bps: u64,
            maturity_timestamp: u64,
        ) -> u64 {
            assert(!self.paused.read(), 'Protocol is paused');
            assert(face_value > 0, 'Face value must be positive');
            assert(discount_rate_bps <= 5000, 'Max discount rate is 50%');

            let current_time = get_block_timestamp();
            assert(maturity_timestamp > current_time, 'Maturity must be future');

            let caller = get_caller_address();
            let issuance_price = calculate_discounted_issuance_price(face_value, discount_rate_bps);
            let senior_yield = face_value - issuance_price;

            let mut tranche = self.tranche.read();
            tranche.senior_principal += issuance_price;
            tranche.senior_yield_owed += senior_yield;
            tranche.total_reserves += issuance_price;
            self.tranche.write(tranche);

            let new_bond_id = self.bond_count.read() + 1;
            self.bond_count.write(new_bond_id);

            let bond = Bond {
                bond_id: new_bond_id,
                issuer: caller,
                holder,
                principal_collateral: issuance_price,
                face_value,
                discount_rate_bps,
                issue_timestamp: current_time,
                maturity_timestamp,
                is_redeemed: false,
                is_defaulted: false,
            };

            self.bonds.write(new_bond_id, bond);

            self.emit(Event::BondIssued(BondIssued {
                bond_id: new_bond_id,
                issuer: caller,
                holder,
                face_value,
                issuance_price,
                maturity_timestamp,
            }));

            new_bond_id
        }

        fn redeem_bond(
            ref self: ContractState,
            bond_id: u64,
        ) -> u256 {
            assert(!self.paused.read(), 'Protocol is paused');
            let mut bond = self.bonds.read(bond_id);
            assert(!bond.is_redeemed, 'Bond already redeemed');
            assert(!bond.is_defaulted, 'Bond defaulted');

            let current_time = get_block_timestamp();
            let payout = calculate_early_redemption_value(
                bond.face_value,
                bond.discount_rate_bps,
                bond.issue_timestamp,
                bond.maturity_timestamp,
                current_time,
            );

            bond.is_redeemed = true;
            self.bonds.write(bond_id, bond);

            let mut tranche = self.tranche.read();
            if tranche.total_reserves >= payout {
                tranche.total_reserves -= payout;
            } else {
                tranche.total_reserves = 0;
            }
            if tranche.senior_principal >= bond.principal_collateral {
                tranche.senior_principal -= bond.principal_collateral;
            } else {
                tranche.senior_principal = 0;
            }
            let yield_paid = payout - bond.principal_collateral;
            if tranche.senior_yield_owed >= yield_paid {
                tranche.senior_yield_owed -= yield_paid;
            } else {
                tranche.senior_yield_owed = 0;
            }
            self.tranche.write(tranche);

            let is_early = current_time < bond.maturity_timestamp;
            self.emit(Event::BondRedeemed(BondRedeemed {
                bond_id,
                holder: bond.holder,
                payout_amount: payout,
                is_early,
            }));

            payout
        }

        fn deposit_junior_buffer(ref self: ContractState, amount: u256) {
            assert(amount > 0, 'Amount must be positive');
            let caller = get_caller_address();

            let mut tranche = self.tranche.read();
            tranche.junior_buffer += amount;
            tranche.total_reserves += amount;
            self.tranche.write(tranche);

            self.emit(Event::JuniorDepositAdded(JuniorDepositAdded {
                depositor: caller,
                amount,
                new_junior_buffer: tranche.junior_buffer,
            }));
        }

        fn absorb_protocol_loss(ref self: ContractState, loss_amount: u256) -> (u256, u256) {
            let caller = get_caller_address();
            assert(caller == self.admin.read(), 'Unauthorized: only admin');

            let mut tranche = self.tranche.read();
            let (new_junior, senior_haircut) = calculate_junior_loss_absorption(
                loss_amount, tranche.junior_buffer,
            );
            let junior_absorbed = tranche.junior_buffer - new_junior;
            tranche.junior_buffer = new_junior;

            if tranche.total_reserves >= loss_amount {
                tranche.total_reserves -= loss_amount;
            } else {
                tranche.total_reserves = 0;
            }

            if senior_haircut > 0 {
                if tranche.senior_principal >= senior_haircut {
                    tranche.senior_principal -= senior_haircut;
                } else {
                    tranche.senior_principal = 0;
                }
            }

            self.tranche.write(tranche);

            self.emit(Event::LossAbsorbed(LossAbsorbed {
                loss_amount,
                junior_absorbed,
                senior_haircut,
            }));

            (junior_absorbed, senior_haircut)
        }

        fn get_bond(self: @ContractState, bond_id: u64) -> Bond {
            self.bonds.read(bond_id)
        }

        fn get_tranche(self: @ContractState) -> TrancheState {
            self.tranche.read()
        }
    }
}
