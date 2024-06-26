use aiken/dict
use aiken/list
use aiken/transaction.{
  InlineDatum, Input, Output, ScriptContext, Spend, Transaction, WithdrawFrom,
  find_script_outputs,
}
use aiken/transaction/credential.{Inline, ScriptCredential}
use aiken/transaction/value.{lovelace_of, quantity_of}
use types.{
  AssetClass, CollateralDatum, LoanAndInterestAmount, OfferLoanDatum,
  ValidateLoanInfo,
}
use utils.{
  get_inputs_from_script, get_lower_bound, resolve_output_reference,
  transaction_signed,
}

type LoanRedeemer {
  CancelLoan(Int)
  GetLoan(Int)
}

type Redeemer {
  action: LoanRedeemer,
}

pub fn get_input_lovelace_amount(
  output: Output,
  loan_asset: AssetClass,
  amount: Int,
) -> Int {
  if loan_asset.policy_id == "" {
    amount
  } else {
    lovelace_of(output.value)
  }
}

fn get_total_repay_amount(
  list: List<Input>,
  inputs_from_script_validator: List<Input>,
) -> LoanAndInterestAmount {
  list.foldl(
    inputs_from_script_validator,
    LoanAndInterestAmount { loan_amount: 0, interest_amount: 0 },
    fn(input: Input, acc: LoanAndInterestAmount) {
      expect InlineDatum(loan_datum) = input.output.datum
      expect loan_datum_typed: OfferLoanDatum = loan_datum
      let interest_amount: Int = loan_datum_typed.interest_amount
      let loan_amount: Int =
        quantity_of(
          input.output.value,
          loan_datum_typed.loan_asset.policy_id,
          loan_datum_typed.loan_asset.asset_name,
        )

      LoanAndInterestAmount {
        loan_amount: acc.loan_amount + loan_amount,
        interest_amount: acc.interest_amount + interest_amount,
      }
    },
  )
}

fn get_inputs_loan_info(
  inputs_from_script: List<Input>,
) -> List<ValidateLoanInfo> {
  list.foldl(
    inputs_from_script,
    [],
    fn(input, inputs_loan) {
      let output: Output = input.output
      expect InlineDatum(loan_offer_datum) = output.datum
      expect loan_offer_datum_typed: OfferLoanDatum = loan_offer_datum

      when
        list.find(
          inputs_loan,
          fn(input_loan: ValidateLoanInfo) {
            input_loan.lender_address_hash == loan_offer_datum_typed.lender_address_hash && input_loan.loan_asset == loan_offer_datum_typed.loan_asset && input_loan.collateral_asset == loan_offer_datum_typed.collateral_asset && input_loan.interest_asset == loan_offer_datum_typed.interest_asset && input_loan.loan_duration == loan_offer_datum_typed.loan_duration
          },
        )
      is {
        Some(duplicate_loan) -> {
          let new_input_loan_info =
            ValidateLoanInfo {
              loan_amount: duplicate_loan.loan_amount + quantity_of(
                output.value,
                loan_offer_datum_typed.loan_asset.policy_id,
                loan_offer_datum_typed.loan_asset.asset_name,
              ),
              loan_asset: loan_offer_datum_typed.loan_asset,
              collateral_amount: loan_offer_datum_typed.collateral_amount + duplicate_loan.collateral_amount,
              collateral_asset: loan_offer_datum_typed.collateral_asset,
              interest_amount: loan_offer_datum_typed.interest_amount + duplicate_loan.interest_amount,
              interest_asset: loan_offer_datum_typed.interest_asset,
              lender_address_hash: loan_offer_datum_typed.lender_address_hash,
              loan_duration: loan_offer_datum_typed.loan_duration,
              lovelace_amount: duplicate_loan.lovelace_amount + get_input_lovelace_amount(
                output,
                loan_offer_datum_typed.loan_asset,
                loan_offer_datum_typed.collateral_amount,
              ),
              liquidation_policy: loan_offer_datum_typed.liquidation_policy,
              collateral_factor: loan_offer_datum_typed.collateral_factor,
            }

          let removed_duplicate_collateral_list =
            list.filter(
              inputs_loan,
              fn(input_loan: ValidateLoanInfo) {
                input_loan.lender_address_hash != loan_offer_datum_typed.lender_address_hash
              },
            )

          [new_input_loan_info, ..removed_duplicate_collateral_list]
        }

        None -> {
          let input_loan_info =
            ValidateLoanInfo {
              loan_amount: quantity_of(
                output.value,
                loan_offer_datum_typed.loan_asset.policy_id,
                loan_offer_datum_typed.loan_asset.asset_name,
              ),
              loan_asset: loan_offer_datum_typed.loan_asset,
              collateral_amount: loan_offer_datum_typed.collateral_amount,
              collateral_asset: loan_offer_datum_typed.collateral_asset,
              interest_amount: loan_offer_datum_typed.interest_amount,
              interest_asset: loan_offer_datum_typed.interest_asset,
              lender_address_hash: loan_offer_datum_typed.lender_address_hash,
              loan_duration: loan_offer_datum_typed.loan_duration,
              lovelace_amount: get_input_lovelace_amount(
                output,
                loan_offer_datum_typed.loan_asset,
                loan_offer_datum_typed.collateral_amount,
              ),
              liquidation_policy: loan_offer_datum_typed.liquidation_policy,
              collateral_factor: loan_offer_datum_typed.collateral_factor,
            }

          [input_loan_info, ..inputs_loan]
        }
      }
    },
  )
}

fn get_outputs_collateral_info(
  script_outputs: List<Output>,
  total_repay_amount: LoanAndInterestAmount,
  ctx: ScriptContext,
) -> List<ValidateLoanInfo> {
  list.filter_map(
    script_outputs,
    fn(output: Output) {
      expect InlineDatum(collateral_datum) = output.datum
      expect collateral_datum_typed: CollateralDatum = collateral_datum

      let lend_time_valid =
        collateral_datum_typed.lend_time == get_lower_bound(
          ctx.transaction.validity_range,
        )
      let total_loan_amount_valid =
        collateral_datum_typed.total_loan_amount == total_repay_amount.loan_amount
      let total_interest_amount_valid =
        collateral_datum_typed.total_interest_amount == total_repay_amount.interest_amount
      let loan_and_asset_same =
        collateral_datum_typed.loan_asset == collateral_datum_typed.interest_asset
      let output_datum_valid =
        lend_time_valid && total_loan_amount_valid && total_interest_amount_valid && loan_and_asset_same

      if output_datum_valid {
        let output_collateral_info =
          ValidateLoanInfo {
            loan_amount: collateral_datum_typed.loan_amount,
            loan_asset: collateral_datum_typed.loan_asset,
            collateral_amount: quantity_of(
              output.value,
              collateral_datum_typed.collateral_asset.policy_id,
              collateral_datum_typed.collateral_asset.asset_name,
            ),
            collateral_asset: collateral_datum_typed.collateral_asset,
            interest_amount: collateral_datum_typed.interest_amount,
            interest_asset: collateral_datum_typed.interest_asset,
            lender_address_hash: collateral_datum_typed.lender_address_hash,
            loan_duration: collateral_datum_typed.loan_duration,
            lovelace_amount: lovelace_of(output.value),
            liquidation_policy: collateral_datum_typed.liquidation_policy,
            collateral_factor: collateral_datum_typed.collateral_factor,
          }

        Some(output_collateral_info)
      } else {
        None
      }
    },
  )
}

fn loan_is_valid(
  ctx: ScriptContext,
  collateral_validator_hash: ByteArray,
  loan_validator_hash: ByteArray,
) -> Bool {
  let outputs_to_collateral_validator: List<Output> =
    find_script_outputs(ctx.transaction.outputs, collateral_validator_hash)

  let inputs_from_script_validator: List<Input> =
    get_inputs_from_script(ctx.transaction.inputs, loan_validator_hash)

  let total_repay_amount: LoanAndInterestAmount =
    get_total_repay_amount(ctx.transaction.inputs, inputs_from_script_validator)

  let inputs_loan_info: List<ValidateLoanInfo> =
    get_inputs_loan_info(inputs_from_script_validator)

  let outputs_collateral_info: List<ValidateLoanInfo> =
    get_outputs_collateral_info(
      outputs_to_collateral_validator,
      total_repay_amount,
      ctx,
    )

  let info_difference =
    list.difference(inputs_loan_info, outputs_collateral_info)
  let info_matches = list.length(info_difference) == 0
  let length_matches =
    list.length(inputs_loan_info) == list.length(outputs_collateral_info)

  info_matches && length_matches
}

validator(collateral_validator_hash: ByteArray) {
  fn spend(
    datum: OfferLoanDatum,
    redeemer: Redeemer,
    ctx: ScriptContext,
  ) -> Bool {
    when redeemer.action is {
      CancelLoan(_) -> transaction_signed(ctx, datum.lender_address_hash)

      GetLoan(_) -> {
        expect ScriptContext { transaction: tx, purpose: Spend(own_ref) } = ctx

        let Transaction { inputs, withdrawals, .. } = tx

        let Output { address: own_addr, .. } =
          resolve_output_reference(inputs, own_ref)

        let own_withdrawal = Inline(own_addr.payment_credential)

        dict.has_key(withdrawals, own_withdrawal)
      }
    }
  }

  fn withdraw(_redeemer: Int, ctx: ScriptContext) {
    expect ScriptContext { transaction: _tx, purpose: WithdrawFrom(stake_cred) } =
      ctx

    expect Inline(ScriptCredential(loan_validator_hash)) = stake_cred
    loan_is_valid(ctx, collateral_validator_hash, loan_validator_hash)
  }
}
