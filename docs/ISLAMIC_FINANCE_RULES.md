# Islamic finance rules for installment sales

*Owner decision, 15 Oct 2026 (EC-80). Binding for every installment slice: N01 rules engine, N02 sale and contract, N03 collections, N04 overdue and late fees, N05 early settlement / rescheduling / write-off, N07 printed contract, and the reports that show profit. A spec that has to leave one of these rules stops and asks the owner.*

**Status:** the owner's direction, based on the majority view (Egypt's Dar al-Ifta, AAOIFI Shari'ah Standard 8 on murabaha). Scholars differ on details (late penalties, early-settlement discounts). Before the shop goes live with installments, the owner confirms these rules with Dar al-Ifta or a Sharia advisor; any change comes back here first.

## The model: a deferred-price sale, not a loan
An installment sale is a **sale of goods the shop already owns, at a fixed deferred price paid in installments** (*bay' bil-taqsit*, a murabaha when the cost is disclosed). The shop's gain is **part of the sale price**, earned once by the sale. It is not interest on money and it does not grow with time.

## The rules

1. **One price, fixed at signing.** The installment price (`total_payable` = financed amount + profit) and every installment's amount and due date are set when the contract is made and printed on it. Nothing in the system may raise them afterwards. The cash price and the installment price may both be shown before the sale, but the customer chooses **one** before signing; the contract states only the chosen one.
2. **The profit belongs to the price, not to time.** The policy's markup % is the profit for the **whole term** (a shop may charge more for longer terms through duration tiers, because the price is fixed once at signing). No per-month or per-day rate is shown, stored as the basis of the price, or accrued.
3. **Words.** Screens, receipts, contracts, reports and translations say **profit** (Arabic **ربح** / **ربح البيع بالتقسيط**) and **installment price** (**سعر البيع بالتقسيط**), never **interest** (**فائدة**), **rate** (**سعر الفائدة**) or **loan** (**قرض**). Internal column names (`markup_pct`, `markup_amount`) may stay; anything a person reads follows this rule. Reviewers reject a user-visible "interest".
4. **No increase for late payment.** A late customer never owes more to the shop because of the delay (that is riba). N04 therefore supports:
   - **no late fee** (the default for a new policy, `late_fee_type = 'none'`), or
   - a **late-payment penalty given to charity** (the AAOIFI approach, to discourage deliberate delay): it is recorded as a separate charge, never counted as the shop's income or profit, and tracked in its own charity balance until it is paid out to a charity, with an audit trail. The owner turns it on deliberately; it is off by default.
   Actual, documented collection costs are a separate question for the Sharia advisor and are **not** built until answered.
   Marking an installment overdue, warnings, banning a customer from new installment sales and legal referral stay allowed (they don't add to the debt).
5. **No increase for more time.** A reschedule (N05) spreads the **remaining balance** over a new schedule; the new schedule's total equals what is still owed, never more ("pay or increase" is the classic riba). Fewer, larger installments or more, smaller ones are both fine as long as the total doesn't grow. The old schedule is kept and linked, as the slice says.
6. **Early settlement discount is the shop's free choice, never a promise.** A customer who pays early owes the remaining installment price. A manager may **voluntarily waive** part of the remaining profit at the time of settlement (*ibra'*). The contract, the receipt and the customer screens never promise a discount in advance. The policy's `early_settlement_rule` / `early_settlement_pct` are only the **suggested** waiver the manager sees (N05 applies it as a manager's decision with a reason and an audit row, not automatically).
7. **The shop owns what it sells.** An installment sale sells stock the shop owns (the POS sells from its own stock; S01). A contract made from an order (`contracts.order_id`, S10) for goods the shop hasn't received yet is an open question: N02's spec settles it with the Sharia advisor before building that path (a deposit on an order is fine either way).
8. **Write-off stays allowed.** Writing off a balance that can't be collected (N05) forgives debt; it never adds to it.
9. **How the profit is split is accounting only.** Splitting each installment into principal and profit (N01: in proportion to the amounts) is for the books and reports; it doesn't change what the customer owes.

## What this changes in the plans
- **N01:** markup for the whole term; the eight N01 questions are answered (see `docs/tasks/N01.md`).
- **N04:** no late fee by default; the only other option is a charity penalty that never reaches the shop's income (rule 4). The slice text in `EcoTech_Pro_Slices.md` points here.
- **N05:** a reschedule never increases the total (rule 5); the early-settlement discount is a manager's waiver at settlement time (rule 6). D74's account formula ("what a reschedule added") stays harmless because a reschedule adds nothing.
- **N07:** the printed contract shows the installment price, the schedule and the words of rule 3, and no discount promise (rule 6).
- **Reports (D0x):** profit is reported as sale profit; charity penalties are reported apart and never as income.
