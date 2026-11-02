pub fn calculate_discounted_issuance_price(face_value: u256, discount_bps: u64) -> u256 {
    if discount_bps >= 10000 {
        return 0;
    }
    let discount_rate: u256 = discount_bps.into();
    let discount_amount = (face_value * discount_rate) / 10000;
    face_value - discount_amount
}

pub fn calculate_early_redemption_value(
    face_value: u256,
    discount_bps: u64,
    issue_time: u64,
    maturity_time: u64,
    current_time: u64,
) -> u256 {
    if current_time >= maturity_time {
        return face_value;
    }
    let discounted_price = calculate_discounted_issuance_price(face_value, discount_bps);
    if current_time <= issue_time {
        return discounted_price;
    }

    let duration: u256 = (maturity_time - issue_time).into();
    let elapsed: u256 = (current_time - issue_time).into();
    let discount_total = face_value - discounted_price;
    let accrued_discount = (discount_total * elapsed) / duration;

    discounted_price + accrued_discount
}

pub fn calculate_junior_loss_absorption(loss_amount: u256, junior_buffer: u256) -> (u256, u256) {
    if loss_amount <= junior_buffer {
        (junior_buffer - loss_amount, 0)
    } else {
        (0, loss_amount - junior_buffer)
    }
}

pub fn calculate_junior_surplus_yield(total_profit: u256, senior_yield_due: u256) -> (u256, u256) {
    if total_profit <= senior_yield_due {
        (total_profit, 0)
    } else {
        (senior_yield_due, total_profit - senior_yield_due)
    }
}
