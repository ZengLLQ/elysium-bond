use crate::math::{
    calculate_discounted_issuance_price, calculate_early_redemption_value,
    calculate_junior_loss_absorption, calculate_junior_surplus_yield,
};

#[test]
fn test_discounted_issuance_pricing() {
    let face_value: u256 = 10000;
    let discount_bps: u64 = 500; // 5%

    let price = calculate_discounted_issuance_price(face_value, discount_bps);
    // 5% of 10000 is 500 -> Price = 9500
    assert(price == 9500, 'Price should be 9500');

    let face_value_2: u256 = 50000;
    let discount_bps_2: u64 = 1000; // 10%
    let price_2 = calculate_discounted_issuance_price(face_value_2, discount_bps_2);
    // 10% of 50000 is 5000 -> Price = 45000
    assert(price_2 == 45000, 'Price should be 45000');
}

#[test]
fn test_early_redemption_linear_accretion() {
    let face_value: u256 = 10000;
    let discount_bps: u64 = 500; // Price = 9500, Discount = 500
    let issue_time: u64 = 1000;
    let maturity_time: u64 = 2000; // Duration = 1000 sec

    // 1. Exactly at issue time: returns 9500
    let v_start = calculate_early_redemption_value(
        face_value, discount_bps, issue_time, maturity_time, 1000,
    );
    assert(v_start == 9500, 'Start value should be 9500');

    // 2. Exactly halfway (timestamp 1500): 9500 + 250 = 9750
    let v_half = calculate_early_redemption_value(
        face_value, discount_bps, issue_time, maturity_time, 1500,
    );
    assert(v_half == 9750, 'Half value should be 9750');

    // 3. Three quarters (timestamp 1750): 9500 + 375 = 9875
    let v_3q = calculate_early_redemption_value(
        face_value, discount_bps, issue_time, maturity_time, 1750,
    );
    assert(v_3q == 9875, '3/4 value should be 9875');

    // 4. At maturity: full face value 10000
    let v_mature = calculate_early_redemption_value(
        face_value, discount_bps, issue_time, maturity_time, 2000,
    );
    assert(v_mature == 10000, 'Mature value should be 10000');

    // 5. Past maturity: stays 10000
    let v_past = calculate_early_redemption_value(
        face_value, discount_bps, issue_time, maturity_time, 3500,
    );
    assert(v_past == 10000, 'Past mature should be 10000');
}

#[test]
fn test_junior_first_loss_absorption() {
    let junior_buffer: u256 = 5000;
    let loss_amount: u256 = 3000;

    let (remaining_junior, senior_haircut) = calculate_junior_loss_absorption(
        loss_amount, junior_buffer,
    );

    // Junior absorbs all 3000 loss -> Remaining junior = 2000, Senior haircut = 0
    assert(remaining_junior == 2000, 'Junior should be 2000');
    assert(senior_haircut == 0, 'Senior haircut should be 0');
}

#[test]
fn test_junior_deficit_and_senior_haircut() {
    let junior_buffer: u256 = 2000;
    let loss_amount: u256 = 3500;

    let (remaining_junior, senior_haircut) = calculate_junior_loss_absorption(
        loss_amount, junior_buffer,
    );

    // Junior wiped to 0 -> Senior suffers 1500 haircut
    assert(remaining_junior == 0, 'Junior should be wiped');
    assert(senior_haircut == 1500, 'Senior haircut should be 1500');
}

#[test]
fn test_surplus_yield_distribution() {
    let total_profit: u256 = 1500;
    let senior_yield_due: u256 = 1000;

    let (senior_paid, junior_surplus) = calculate_junior_surplus_yield(
        total_profit, senior_yield_due,
    );

    assert(senior_paid == 1000, 'Senior should get 1000');
    assert(junior_surplus == 500, 'Junior should get 500 surplus');
}

#[test]
fn test_loss_absorption_conservation_invariant() {
    let junior_buffer: u256 = 4000;
    let test_losses: Array<u256> = array![500, 2000, 4000, 5000, 10000];
    let mut i: usize = 0;

    while i < test_losses.len() {
        let loss = *test_losses.at(i);
        let (rem_junior, senior_haircut) = calculate_junior_loss_absorption(loss, junior_buffer);
        let junior_absorbed = junior_buffer - rem_junior;

        // Invariant: junior_absorbed + senior_haircut must equal loss
        assert(junior_absorbed + senior_haircut == loss, 'Conservation invariant broken');
        i += 1;
    }
}
