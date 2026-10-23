# Changelog

## 0.60.0

- D03 receivables aging: in `reports.ts`, RECEIVABLES_GROUP_BY / ReceivablesGroupBy (customer, branch, collector, contract), RECEIVABLES_SORTS / ReceivablesSort, RECEIVABLES_BUCKETS / ReceivablesBucket (not_due, late_1_30, late_31_60, late_61_90, late_90_plus), RECEIVABLES_NO_COLLECTOR (`none`), RECEIVABLES_MAX_MIN_DAYS, RECEIVABLES_MAX_Q, ReceivablesQuery (strict; `collector_id` a uuid or `none`; `q` only with the customer or contract grouping, at most 100 characters; `min_days` 1-100000; page_size 1-1000), ReceivablesMeasures, ReceivablesRow (customer / collector / branch / contract references by grouping), ReceivablesBucketSplit, ReceivablesTotals (each bucket split into principal and profit), ReceivablesCheck, ReceivablesReport. Money and percentages are strings; no fee member (rule 4). No new error code.

## 0.59.0

- D02 sales and margin report: new `reports.ts` with SALES_REPORT_GROUP_BY / SalesReportGroupBy (day, month, branch, employee, category, product, sale_type, payment_type), SALES_REPORT_SORTS / SalesReportSort, SALES_REPORT_COST_SORTS, SalesReportSaleType, SALES_REPORT_MAX_DAYS, SALES_REPORT_MAX_PAGE_SIZE, SALES_REPORT_DEFAULT_PAGE_SIZE, salesReportDays, SalesReportQuery (dates `YYYY-MM-DD`, at most 366 days, `category_level` leaf | top, page_size 1-1000; strict; product / category filters refused for `payment_type`), SalesReportMeasures, SalesReportRow, SalesReportTotals, SalesReportCheck, SalesReport. Money and percentages are strings; every cost-derived value is `null` without `report.financial` (`can_see_cost` false). No new error code.

## 0.58.0

- S05 returns and exchanges: new `returns.ts` with RETURN_KINDS / ReturnKind, SalesReturnKind, RETURN_CONDITIONS / ReturnCondition, RefundMethod, ReturnReason, ReturnLineInput, ReturnLines, RefundLineInput, RefundLines, ExchangeNewSaleInput, SalesReturnQuoteBody, SalesReturnCreateBody, ReturnIdParams, RefundLine, RefundableByMethod, ReturnContractPlan, SalesReturnQuoteLine, SalesReturnQuote, SaleReturnableLine, SALE_RETURN_BLOCKS / SaleReturnBlock, SaleReturnable, SalesReturnLine, SalesReturnRefund, SalesReturn, SalesReturnListQuery, SalesReturnSummary, SalesReturnListResponse, SalesReturnReceiptPrint, ClaimRefundTarget (S12's refund now answers it), SaleReturnQtyExceededDetail, RefundExceedsPaidDetail, ReturnPeriodExpiredDetail. Error codes RETURN_NOT_FOUND (404), RETURN_UNIT_MISMATCH, RETURN_PERIOD_EXPIRED, RETURN_OTHER_BRANCH, REFUND_EXCEEDS_PAID, RETURN_ETA_WINDOW_PASSED, EXCHANGE_NOT_FOR_CONTRACT (409). No new permission key (`refund.create` exists) and no new enum value.

## 0.57.0

- D01 owner dashboard: new `dashboard.ts` with DashboardQuery, OwnerDashboard (business_date, branch_id, generated_at, one nullable tile per key), DASHBOARD_TILES, DashboardTileKey, DashboardSalesTile, DashboardCollectionsTile, DashboardCashTile, DashboardShiftsTile, DashboardOverdueTile, DashboardLowStockTile, DashboardEtaTile, DashboardUnclosedDaysTile, DashboardApprovalsTile. A tile is `null` when the caller lacks the permission its detail page needs. Existing error codes only (BRANCH_NOT_FOUND, BRANCH_DENIED, VALIDATION_FAILED). No new permission key and no new enum value.

## 0.56.0

- M03 full export: new `exports.ts` with EXPORT_LIMITS, EXPORT_STATUSES / ExportStatus, EXPORT_PII_MODES / ExportPiiMode, StartExportBody, ExportIdParams, EXPORT_FAILURE_CODES / ExportFailureCode, ExportRequester, ExportJob, ExportListResponse, EXPORT_MANIFEST_FORMAT_VERSION, ExportManifestTable, ExportManifestTotals, ExportManifest, ExportRunningDetail, ExportTooSoonDetail. Error codes EXPORT_RUNNING (409), EXPORT_TOO_SOON (429) and EXPORT_NOT_FOUND (404); EXPORT_TOO_LARGE is reused. No new permission key (`export.data`, `customer.view_pii` exist) and no new enum value.

## 0.55.0

- M02 opening balances: `IMPORT_KINDS` / `IMPORT_KIND_ORDER` gain `opening_contracts` and `opening_cash` (`IMPORT_COLUMNS` for both: one row per remaining installment with the contract columns repeated, guarantors 1 and 2, and one row per safe / bank), 11 new `IMPORT_ROW_ERROR_CODES` (IMPORT_CONTRACT_ROWS_DIFFER, IMPORT_CONTRACT_NOT_BALANCED, IMPORT_CONTRACT_EXISTS, IMPORT_CUSTOMER_NOT_FOUND, IMPORT_GUARANTOR_INCOMPLETE, IMPORT_ACCOUNT_KIND, CASH_ACCOUNT_HAS_MOVEMENTS, CASH_ACCOUNT_INACTIVE, CASH_ACCOUNT_NAME_TAKEN, DAY_CLOSED, POLICY_NOT_SET), `ImportReport.summary` and `.contracts` (ImportContractsSummary, ImportContractPreview). New `migration.ts`: ContractMigrationSource, MigrationReportQuery, MigrationReport (totals, customers, branches, batches, cash), MigrationReportTotals / Customer / Branch / Batch / Cash, MigrationBlocker, MIGRATION_BLOCKER_REASONS, MigrationAmount, MigrationSignOffBody, MigrationSignOff, MigrationSignOffList, MigrationTotalMismatchDetail, MigrationSignedOffDetail, MigrationBatchParams, ReverseMigrationBatchBody, MigrationBatchReversal, MigrationNotReversibleDetail. `Contract.migration_source` and `CustomerContractSummary.migration_source` (nullable, optional). Error codes MIGRATION_TOTAL_MISMATCH, MIGRATION_SIGNED_OFF and MIGRATION_NOT_REVERSIBLE (409). No new permission key and no new enum value.

## 0.54.0

- K04 day close and reconciliation: DAY_CLOSE_STATUSES, DayCloseStatus, DAY_CLOSE_ISSUE_SEVERITIES, DayCloseIssueSeverity, DAY_CLOSE_ISSUE_CODES, DayCloseIssueCode, DAY_CLOSE_LINK_KINDS, DayCloseLinkKind, DayCloseIssue, DayCloseByMethod, DayCloseCashAccount, DayCloseShift, DayCloseEta, DayCloseTotals, DayClose, DayClosePreview, DayClosePreviewQuery, DayCloseListQuery, DayCloseListItem, DayCloseListResponse, DayCloseIdParams, DAY_CLOSE_NOTE_MAX_LENGTH, CloseDayBody, ReopenDayBody, DayCloseAlerts, DayAlreadyClosedDetail, DayCloseBlockedDetail, dayCloseNeedsNote, dayCloseBlockers. Error codes DAY_ALREADY_CLOSED, DAY_NOT_CLOSED, DAY_CLOSE_BLOCKED, DAY_CHANGED (409) and NOTE_REQUIRED (422). No new permission key (`day.close`, `day.reopen` exist) and no new enum value.

## 0.53.0

- M01 import (products, customers, suppliers, opening stock): IMPORT_KINDS, ImportKind, IMPORT_KIND_ORDER, IMPORT_STATUSES, ImportStatus, IMPORT_MAX_BYTES, IMPORT_MAX_ROWS, IMPORT_MAX_REPORTED_ERRORS, IMPORT_PREVIEW_ROWS, IMPORT_COLUMN_TYPES, ImportColumnType, ImportColumnDef, IMPORT_COLUMNS (one column registry per kind: labels, aliases, required, example, help; drives the template, the header matching and the Web mapping screen), importColumn, normalizeImportHeader, suggestImportMapping, missingImportColumns, ImportMappingSuggestion, ImportMapping, ImportKindParams, ImportTemplateQuery, ImportIdParams, InspectImportBody, ImportInspection, CreateImportBody, RunImportBody, ImportListQuery, ImportListQueryInput, IMPORT_ROW_ERROR_CODES, ImportRowErrorCode, ImportRowError, ImportRowAction, ImportWarning, ImportPreviewRow, ImportActions, ImportReport, ImportUserRef, ImportJob, ImportJobSummary, ImportListResponse, ImportMissingColumnsDetail, ImportNotValidatedDetail. Error codes IMPORT_FILE_UNREADABLE, IMPORT_MISSING_COLUMNS, IMPORT_MAPPING_INVALID, IMPORT_SHEET_NOT_FOUND (422), IMPORT_TOO_MANY_ROWS (413), IMPORT_NOT_VALIDATED (409), IMPORT_JOB_NOT_FOUND (404). No new permission key (`import.data` exists) and no new enum value.

## 0.52.0

- N07 printed contract and promissory notes: CONTRACT_DOCUMENT_KINDS, ContractDocumentKind, ContractDocumentPrintBody, ContractDocumentPrint, DocumentParty, DocumentGuarantor, DocumentGood, DocumentShop, PromissoryNote, ContractDocumentContract, ContractDocuments, CONTRACT_STATUS_MARKS, CONTRACT_TERMS_MAX_LENGTH, CONTRACT_TEMPLATE_PLACEHOLDERS, CONTRACT_TEMPLATE_FORBIDDEN_WORDS, ContractTemplatePlaceholder, ContractTemplateCheck, checkContractTemplate, renderContractTemplate, DEFAULT_CONTRACT_TERMS_AR, amountInWordsAr, TemplateInvalidDetail, TemplateNotAllowedDetail, PROMISSORY_NOTES_MODES, PromissoryNotesMode. `ShopSettings` and `ShopSettingsUpdateBody` gain `contract_terms` (nullable; null = the default text) and `promissory_notes_mode` (`per_installment` | `single`). Error codes TEMPLATE_INVALID (422) and TEMPLATE_NOT_ALLOWED (422). No new permission key and no new enum value.

## 0.51.0

- N06 collector wallets: FieldCollectionBody, WalletCollectorRef, WalletLastSettlement, MyWallet, WalletRow, WalletListQuery, WalletListResponse, WalletIdParams, WalletMovementQuery, WalletMovement, WalletMovementPage, SettleWalletBody, WalletSettlement, WalletBalanceDetail, SetCustomerCollectorBody, CollectorRouteQuery, CollectorRouteContract, CollectorRouteStop, CollectorRoute, CustomerCollector. `Customer.collector` (nullable); `OverdueListQuery.collector_id` and `OverdueCustomerRef.collector_id`; `COLLECTION_NOT_REVERSIBLE_REASONS` gains `handed_in`. Error codes CUSTOMER_NOT_ASSIGNED (403), COLLECTOR_INVALID (422), WALLET_BALANCE_CHANGED (409), SELF_SETTLEMENT (403), WALLET_NOT_FOUND (404). `collector_commission_pct` is deprecated: always 0, never read, still accepted. No new permission key and no new enum value.

## 0.50.0

- N05 early settlement, rescheduling, write-off: CONTRACT_CHANGE_KINDS, ContractChangeKind, ContractChange, SettlementQuote, SettleBody, SettleResponse, ReschedulePreviewBody, RescheduleLine, ReschedulePreview, RescheduleBody, ContractChangeResponse, WriteOffBody, ContractVersionLine, ContractVersion, ContractChangeHistory, ContractChangeListQuery, ContractChangeListQueryInput, ContractChangeListItem, ContractChangeTotals, ContractChangeListPage, WaiverTooHighDetail. Error code WAIVER_TOO_HIGH (422). `COLLECTION_NOT_REVERSIBLE_REASONS` gains `settlement` and `contract_changed`; `CustomerStatementKind` gains `profit_waiver` and `write_off` (credit rows). No new permission key (the baseline's `contract.settle_early`, `schedule.change`, `contract.write_off` are used) and no new contract status.

## 0.49.0

- N04 overdue tracking (no late fees): OVERDUE_ACTION_KINDS, OverdueActionKind, OVERDUE_ACTION_STATUSES, OverdueActionStatus, WARNING_OUTCOMES, WarningOutcome, OverdueListQuery, OverdueListQueryInput, OverdueContractRow, OverdueTotals, OverdueListPage, OverdueAction, OverdueActionPage, OverdueWarningListQuery, OverdueWarningListQueryInput, LegalReferralListQuery, LegalReferralListQueryInput, OverdueActionIdParams, HandleWarningBody, DismissReferralBody, OverdueRunResult, OverdueActionNotOpenDetail. Permissions `overdue.view` (BRANCH_MANAGER, COLLECTOR, ACCOUNTANT, LAWYER) and `overdue.handle` (BRANCH_MANAGER, COLLECTOR). Error codes LATE_FEES_NOT_ALLOWED (422), OVERDUE_ACTION_NOT_OPEN (409), OVERDUE_ACTION_NOT_FOUND (404). `InstallmentPolicyBody` still accepts the late-fee fields, but the server refuses any fee (rule 4). No schedule-line status was added: a line inside its grace days is `due`.

## 0.48.0

- N03 collections: COLLECTION_MAX_CONTRACTS, COLLECTION_MAX_PAYMENTS, CollectionPaymentInput, CollectionContractInput, CollectionBody, CollectionReverseBody, CollectionAllocationLine, CollectionAllocation, ContractDue, ContractDueLine, CollectionPreviewQuery, CollectionPreview, ContractListStatus, ContractListQuery, ContractListQueryInput, ContractListItem, ContractListPage, CollectionPaymentLine, CollectionContract, CollectionReversal, CollectionPrint, Collection, CollectionIdParams, ContractNotOpenDetail, CollectionRemainingDetail, COLLECTION_NOT_REVERSIBLE_REASONS, CollectionNotReversibleDetail. Permission `collection.reverse` (installments; OWNER and BRANCH_MANAGER by default). Error codes CONTRACT_NOT_OPEN, COLLECTION_DUE_CHANGED, COLLECTION_EXCEEDS_REMAINING, COLLECTION_NOT_REVERSIBLE (409), COLLECTION_NOT_FOUND (404).

## 0.47.0

- N02 installment sale and contract: InstallmentSaleTerms, InstallmentSaleBody, InstallmentSaleInput, ContractScheduleLine, ContractGuarantor, Contract, InstallmentSale, ContractIdParams; `SaleLines` and `SalePayments` are exported. Error codes CUSTOMER_NATIONAL_ID_REQUIRED, MARKUP_VAT_NOT_SUPPORTED (409).

## 0.46.0

- N01 installment rules engine: FIRST_DUE_MAX_DAYS, MAX_INSTALLMENTS, INSTALLMENT_VIOLATION_RULES, InstallmentTermsInput, InstallmentViolationRule, InstallmentViolation, ScheduleLinePreview, InstallmentTerms, InstallmentPreviewBody, InstallmentGuarantorCheck, InstallmentPreview, PolicyChangedDetail, InstallmentTermsInvalidDetail, InstallmentEnginePolicy, computeInstallmentTerms, installmentDueDate, installmentDurationMonths. Error codes INSTALLMENT_TERMS_INVALID (400), POLICY_NOT_SET, POLICY_CHANGED, SCHEDULE_NOT_BALANCED (409).

## 0.45.0

- R05 field surveys: SURVEY_CRITERIA, SURVEY_CHECKLIST, SURVEY_STATUSES, SURVEY_MAX_PHOTOS, SURVEY_VALID_DAYS, SURVEY_LOW_ACCURACY_M, SurveyCriterion, SurveyChecklistItem, SurveyStatus, SurveyVisitType, SurveyScores, SurveyScoresComplete, SurveyChecklist, SurveyChecklistComplete, SurveyGps, Survey, SurveyArray, SurveyListQuery, SurveyList, SurveyIdParams, SurveyCreateBody, SurveyReassignBody, SurveyCancelBody, SurveyAnswersBody, SurveySubmitBody, SurveyDecisionBody, SurveyRequirementQuery, SurveyRequirement, CreditLatestSurvey, SurveyAlreadyOpenDetail, SurveyAssigneeInvalidDetail, SurveyRequiredDetail. `CreditProfile.latest_survey` (nullable). Error codes SURVEY_NOT_FOUND (404), SURVEY_NOT_ASSIGNEE (403), SURVEY_ALREADY_OPEN, SURVEY_ASSIGNEE_INVALID, SURVEY_WRONG_STATUS, SURVEY_PHOTO_REQUIRED, SURVEY_SELF_DECISION, SURVEY_REQUIRED (409).

## 0.44.0

- R02 customer account: CUSTOMER_STATEMENT_MAX_YEARS, CustomerAccountHead, CustomerOpenBalance, CustomerAccountBalance, CustomerAging, CustomerOverdue, CustomerAccountTotals, ContractStatus, CustomerContractSummary, PaymentDirection, PaymentAllocationKind, CustomerPaymentSummary, CustomerReturnSummary, CustomerAccount, ScheduleLineStatus, CustomerScheduleLine, CustomerContractCharge, CustomerContractSchedule, CustomerContractParams, CustomerStatementQuery, CustomerStatementKind, CustomerStatementRow, CustomerStatement. Error code CONTRACT_NOT_FOUND (404). (0.43.0 is S09's.)

## 0.42.0

- R03 credit profile and limit: CREDIT_AMOUNT_MAX, CREDIT_EXCEPTION_VALID_HOURS, CreditReason, CreditScoreKey, CreditScoreComponent, CreditBehaviour, CreditLimitChange, CreditProfile, CreditLimitBody, CreditCheckQuery, CreditCheck, CreditExceptionRequestBody, CreditExceptionDecideBody, CreditExceptionStatus, CreditExceptionSnapshot, CreditException, CreditExceptionList, CreditExceptionListQuery, CreditExceptionIdParams, CreditLimitExceededDetail. Error codes CREDIT_LIMIT_EXCEEDED, CREDIT_SCORE_TOO_LOW, CREDIT_CUSTOMER_WATCH, CREDIT_APPROVAL_INVALID (409), CREDIT_REASON_REQUIRED (400); the first three carry CreditLimitExceededDetail.

## 0.41.0

- R04 guarantors: GUARANTOR_RELATIONS, GuarantorRelation, MAX_GUARANTORS_PER_CUSTOMER, MAX_GUARANTORS_PER_CONTRACT, Guarantor, GuarantorDetails, CustomerGuarantor, CustomerGuarantorList, GuarantorListQuery, GuarantorList, GuarantorCreateBody, GuarantorUpdateBody, GuarantorIdParams, CustomerGuarantorParams, CustomerGuarantorLinkBody, CustomerGuarantorRelationBody, GuarantorRequirementQuery, GuarantorRequirement, GuarantorNationalIdTakenDetail, GuarantorRequiredDetail. InstallmentPolicy and InstallmentPolicyBody gain `guarantors_required_count` (1-3). Error codes GUARANTOR_NOT_FOUND (404), GUARANTOR_NATIONAL_ID_TAKEN, GUARANTOR_ALREADY_LINKED, GUARANTOR_NOT_LINKED, GUARANTOR_LIMIT_REACHED, GUARANTOR_IS_CUSTOMER, GUARANTOR_ARCHIVED, GUARANTOR_ON_ACTIVE_CONTRACT, GUARANTOR_REQUIRED, CUSTOMER_BLOCKED (409).

## 0.40.1

- EC-147: ShiftForceCloseBody and optional device_revoked state on shift answers. DEVICE_REVOKED remains 403; DEVICE_MISMATCH remains 409.

## 0.40.0

- T03 ETA monitor and corrections: FiscalSituation, FiscalSituationFilter, FiscalDeadlineState, FiscalAction, FiscalListQuery, FiscalListItem, FiscalList, FiscalAlertSummary, FiscalDaySummaryQuery, FiscalDaySummary, FiscalFix, FiscalSellerField, FiscalEtaError, FiscalProblem, FiscalDiagnosis, FiscalEvent, FiscalDetails, FiscalAssignDeviceBody, FiscalQueued, FiscalRetryManyBody, FiscalRetryManyResult, FISCAL_RETRY_MANY_MAX. Error codes USE_CORRECTION, NOT_REJECTED, CORRECTION_QUEUED, CORRECTION_CONFLICT, NOT_BLOCKED_NO_DEVICE, NOT_SUBMITTED (409), DEVICE_INVALID_FOR_RECEIPT (400).

## 0.39.0

- O03 POS devices: DeviceCreateBody, DeviceCreated, DeviceUpdateBody, DeviceActiveBody (turning a device off needs a reason), DeviceActiveResult, DevicePairingCode (the code is answered once), DeviceUnpaired, DevicePairBody, DevicePaired (the device token is answered once), CurrentDevice, CurrentDeviceResponse, DEVICE_TOKEN_HEADER, PAIRING_CODE_ALPHABET, PAIRING_CODE_LENGTH, PAIRING_CODE_TTL_MINUTES, DEVICE_NAME_MAX. Device gains `paired`, `paired_at`, `last_seen_at`. Error codes DEVICE_REQUIRED, DEVICE_HAS_OPEN_SHIFT, DEVICE_NAME_TAKEN, DEVICE_BRANCH_MISMATCH, DEVICE_MISMATCH (409), DEVICE_REVOKED (403), PAIRING_CODE_INVALID (400).

## 0.38.0

- S04 receipt prints: SaleReceiptPrint (`print_no`, `copy`) for `POST /api/sales/:id/receipt-prints`; SaleHistoryDetails gains `receipt_prints` (optional; 0 means the next print is the original).

## 0.37.0

- Combine S07 sales history, S12 warranty, and T02 ETA e-receipts contracts after merging main.

## 0.36.0

- S12 warranty lookup, claims, transitions and receipt contracts.

## 0.35.0

- S07 branch-scoped sales history, computed status, void eligibility and reversal contracts.

- T02 ETA e-receipts: EtaEnvironment, DeviceEtaStatus, FiscalStatus, EtaSettings (`has_client_secret`, never the secret), EtaSettingsBody (the secret is write-only), EtaTestBody, EtaTestResult, Device (`has_preshared_key`, never the key), DeviceList, DeviceIdParams, DeviceEtaBody, FiscalSubmissionIdParams, FiscalRetryResult, SaleEta, ETA_ACTIVITY_CODE_PATTERN. Sale gains `eta` (status, uuid, qr_payload, last_error_code; null or absent without a receipt). BranchCreateBody, BranchUpdateBody and ManagedBranch gain `building_number`. Error codes DEVICE_NOT_FOUND, FISCAL_NOT_FOUND (404), DEVICE_SERIAL_TAKEN, ETA_ENV_BUSY, ETA_ENV_MISMATCH, FISCAL_NOT_RETRYABLE (409). Money: divideMoney(amount, divisor, decimals), a quotient with a fixed number of decimals (the ETA unit price has 5).

## 0.34.0

- S03 discounts: Discount (amount or percent), DiscountReason. SaleLineInput gains `discount`; SaleQuoteBody gains `sale_discount`; SaleCreateBody gains `sale_discount`, `discount_reason`, `discount_approval_id`. SaleLine and SaleQuoteLine gain `discount_amount`; SaleQuoteLine gains `effective_pct`; SaleQuote gains `discount_total` and `max_effective_pct`; Sale gains `discount_reason`. Approval on the spot: DiscountApprovalRequestBody, DiscountApprovalRequested, DiscountApproval (Line, Status, List, ListQuery, IdParams, DecideBody, Result), DiscountAboveCapDetail. Error codes DISCOUNT_INVALID, DISCOUNT_REASON_REQUIRED, APPROVAL_NOT_NEEDED (400), APPROVAL_INVALID, APPROVAL_NOT_PENDING (409), APPROVAL_SELF (403), APPROVAL_NOT_FOUND (404); DISCOUNT_ABOVE_CAP (403) now carries details.

## 0.33.0

- S02 split payments: SalePaymentInput (cash with optional tendered, bank transfer with account and reference, store credit), SALE_MAX_BANK_TRANSFERS, SalePaymentAccount, SalePaymentAccountList, PaymentTotalMismatchDetail, StoreCreditDetail. SaleQuoteBody and SaleCreateBody gain `payments` (1-5 lines); SaleQuote gains paid, remaining, change, store_credit_balance; SalePayment gains tendered and change; Sale gains paid_total and change_total; Shift and ShiftSummary gain sales_total and payment_totals. Error code PAYMENT_TOTAL_MISMATCH (400, details).

## 0.32.0

- R01 follow-up: `Customer` gains `governorate_code` (read from the national ID, shown to everyone). `CustomerCreateBody` and `CustomerUpdateBody` no longer take `birth_date` or `gender`: the server reads both from the national ID.

## 0.31.0

- R01 customers: CustomerStatus, CustomerGender, CustomerCreateBody, CustomerUpdateBody, CustomerStatusBody (blocking needs a reason), CustomerIdParams, Customer (national_id only with customer.view_pii, national_id_masked for everyone, id_photos_count), CustomerList, CustomerListQuery, CustomerStatusFilter, CustomerNationalIdTakenDetail, normalizeCustomerPhone(), CUSTOMER_MAX_PHONES, CUSTOMER_PHONE_PATTERN, CUSTOMER_TAX_NO_PATTERN. National ID helpers: parseNationalId() (birth date, gender, governorate), isValidNationalId(), normalizeNationalId(), maskNationalId(), toAsciiDigits(), EGYPT_GOVERNORATE_CODES. Error codes CUSTOMER_NOT_FOUND (404), CUSTOMER_NATIONAL_ID_TAKEN (409, details).

## 0.30.0

- S01 sale core: SaleLineInput, SaleQuoteBody, SaleCreateBody (lines, customer_id, expected_total), SaleIdParams, SaleQuote, SaleQuoteLine, Sale, SaleLine, SalePayment, SalePaymentMethod, PriceChangedDetail, OutOfStockDetail. Error codes SALE_NOT_FOUND, CUSTOMER_NOT_FOUND (404), PRODUCT_ARCHIVED, PRICE_CHANGED (409), PRICE_OVERRIDE_DENIED (403).

## 0.29.1

- No schema change. Republishes 0.29.0 (K02 shifts and K03 expenses included): the `contracts-v0.29.0` tag was put on a commit that still held 0.27.0, so that version was never published.

## 0.29.0

- K03 expenses: ExpenseCategory, ExpenseCategoryList, ExpenseCategoryBody, ExpenseCategoryIdParams, ExpenseCategoryListQuery, ExpenseCreateBody (a vault with its branch, or the open shift), ExpenseReverseBody, ExpenseIdParams, Expense, ExpenseList, ExpenseListQuery (include_reversals, default true), ExpenseReportQuery, ExpenseReport. Error codes EXPENSE_NOT_FOUND, EXPENSE_CATEGORY_NOT_FOUND (404), EXPENSE_CATEGORY_NAME_TAKEN, EXPENSE_CATEGORY_ARCHIVED, EXPENSE_ALREADY_REVERSED (409).

## 0.28.0

- K02 shifts: ShiftStatus, SHIFT_DENOMINATIONS, ShiftDenomination, ShiftCounts, ShiftOpenBody (a float needs a safe), ShiftCashBody (in / out with a note), ShiftCloseBody (counts, safe, difference reason), ShiftIdParams, ShiftMovement, Shift, ShiftSummary, ShiftList, CurrentShift, ShiftListQuery, ShiftVault, ShiftVaultList, ShiftVaultQuery, ShiftDifferenceDetail, shiftCountTotal(). Error codes SHIFT_NOT_FOUND (404), SHIFT_ALREADY_OPEN, SHIFT_CLOSED, SHIFT_REQUIRED (409), SHIFT_DIFFERENCE_REASON_REQUIRED (400, details), DEVICE_INVALID (400).

## 0.27.0

- U05 purchase orders: PurchaseOrderStatus, PurchaseOrderLineInput (expected_unit_cost, sales_order_line_id), PurchaseOrderCreateBody, PurchaseOrderUpdateBody, PurchaseOrderCancelBody, PurchaseOrderInvoiceBody (receive lines; none = everything still to come), PurchaseOrderIdParams, PurchaseOrderLine, PurchaseOrder (lines, invoices), PurchaseOrderSummary, PurchaseOrderList, PurchaseOrderListQuery, PoOverReceiptDetail. U02 schemas: PurchaseInvoiceCreateBody gains po_id, PurchaseInvoiceLineInput gains po_line_id, PurchaseInvoice and its summary gain po_id and po_number, lines gain po_line_id (all null without an order). Error codes PURCHASE_ORDER_NOT_FOUND (404), PURCHASE_ORDER_NOT_EDITABLE, PO_NOT_SENT, PO_CLOSED, PO_OVER_RECEIPT (409, details), PO_LINE_MISMATCH, SALES_ORDER_LINE_INVALID (400).

## 0.26.0

- U03 supplier payments: SupplierPaymentAllocationInput, SupplierPaymentCreateBody (allocations add up to the amount, each invoice once), SupplierPaymentReverseBody, SupplierPaymentIdParams, SupplierPaymentAllocation, SupplierPayment, SupplierPaymentSummary, SupplierPaymentList, SupplierPaymentListQuery (include_reversals, default true), OpenSupplierInvoice, OpenSupplierInvoiceList, OpenSupplierInvoiceQuery, PaymentExceedsOutstandingDetail. Error codes SUPPLIER_PAYMENT_NOT_FOUND (404), PAYMENT_EXCEEDS_OUTSTANDING (409, details), ALLOCATION_INVALID (400), PAYMENT_ALREADY_REVERSED (409).

## 0.25.1

- No schema change: 0.25.0 was tagged on the commit before U04 and never published; this is the first published version with the U04 purchase return schemas.

## 0.25.0

- U04 purchase returns: PurchaseReturnLineInput (quantity or unit_ids), PurchaseReturnCreateBody (cash needs cash_account_id), PurchaseReturnIdParams, PurchaseReturnLine, PurchaseReturn, PurchaseReturnSummary, PurchaseReturnList, PurchaseReturnListQuery, ReturnableLine, ReturnableInvoice, ReturnQtyExceededDetail, PayableCashAccount, PayableCashAccountList, PayableCashAccountQuery. Error codes PURCHASE_RETURN_NOT_FOUND (404), PURCHASE_INVOICE_NOT_APPROVED, RETURN_QTY_EXCEEDED (409, details).

## 0.24.0

- K01 vaults: CashAccountKind (safe, bank), CashAccountStatus, CashAccount (balance, is_default), CashAccountList, CashAccountListQuery (status, default active; branch_id; kind), CashAccountCreateBody (a safe needs a branch), CashAccountUpdateBody, CashAccountIdParams, PositiveMoney, CashOpeningBody (amount > 0, note 3-500), CashTransferCreateBody (two different accounts), CashTransfer, CashTransferList, CashTransferListQuery, CashMovementType, CashLedgerRow, CashLedger, CashLedgerQuery. Error codes CASH_ACCOUNT_NOT_FOUND, CASH_TRANSFER_NOT_FOUND (404), CASH_ACCOUNT_NAME_TAKEN, CASH_ACCOUNT_HAS_BALANCE, CASH_ACCOUNT_IS_DEFAULT, CASH_ACCOUNT_HAS_MOVEMENTS (409); CASH_ACCOUNT_INACTIVE was already there, TRANSFER_SAME_ACCOUNT (400).

## 0.23.0

- U06 purchase approval by amount: PurchaseApprovalStatus, PurchaseApproval, PurchaseInvoiceApproveBody (optional note, 3-500), PurchaseApprovalListItem, PurchaseApprovalList, PurchaseApprovalListQuery (status, default pending; branch_id). PurchaseInvoice and PurchaseInvoiceSummary gain `approval` (the latest approval or null). Error codes APPROVAL_OWNER_ONLY (403), APPROVAL_NOTE_REQUIRED (400).

## 0.22.0

- U02 purchase invoices: PurchaseInvoiceStatus, UnitCost, PurchaseInvoiceLineInput (one serial per unit), PurchaseInvoiceCreateBody (1-200 lines, each product once), PurchaseInvoiceUpdateBody, PurchaseInvoiceRejectBody, PurchaseInvoiceIdParams, PurchaseInvoiceLine, PurchaseInvoice, PurchaseInvoiceSummary, PurchaseInvoiceList, PurchaseInvoiceListQuery, SerialsRequiredDetail. Error codes PURCHASE_INVOICE_NOT_FOUND (404), PURCHASE_INVOICE_NOT_EDITABLE, SUPPLIER_INVOICE_NO_TAKEN, SUPPLIER_ARCHIVED (409), SERIALS_REQUIRED (422, details.line_ids).

## 0.21.0

- U01 suppliers: Supplier (with `balance`), SupplierList, SupplierListQuery (search, status), SupplierCreateBody, SupplierUpdateBody (phone without spaces or dashes, SUPPLIER_PHONE_PATTERN, SUPPLIER_TAX_NO_PATTERN, normalizeSupplierPhone), SupplierIdParams, SupplierStatus, SupplierStatementQuery (from <= to), SupplierStatement, SupplierStatementRow, SupplierStatementRowKind, PurchaseRefundMode. Error codes SUPPLIER_NOT_FOUND (404), SUPPLIER_NAME_TAKEN, SUPPLIER_PHONE_TAKEN, SUPPLIER_HAS_BALANCE, SUPPLIER_HAS_OPEN_DOCUMENTS (409).

## 0.18.0

- I04 serial units: Serial (trimmed, upper-cased), SERIAL_PATTERN, UnitRegisterBody, UnitRegistration, SerialTakenDetail, UnitHistoryEntry, UnitSummary, UnitDetail, UnitList, UnitSearchQuery, UnitFindQuery, UnitIdParams. Error codes SERIAL_TAKEN (409, detail: the serials), SERIAL_INVALID (400).

## 0.17.0

- I03 branch transfers: TransferStatus, TransferDiscrepancyReason, StockTransferLineBody, StockTransferCreateBody, StockTransferUpdateBody, StockTransferReceiveLine, StockTransferReceiveBody, StockTransferLine, StockTransferSummary, StockTransfer, StockTransferList, StockTransferListQuery (transfers carry from/to branch names), TransferDestination(List). Error codes STOCK_TRANSFER_NOT_FOUND (404), TRANSFER_SAME_BRANCH (400), TRANSFER_NOT_SENT, TRANSFER_ALREADY_SENT (409).

## 0.16.0

- I02 stock adjustments and counts: AdjustmentReason, ManualAdjustmentReason, StockAdjustmentCreateBody (reason sets the direction, other needs a note), StockAdjustment(Line/Summary/List/ListQuery), StockDocumentIdParams, StockCountStatus, StockCount, StockCountList(Query), StockCountLine, StockCountDetail(Query), StockCountLineFilter, StockCountCreateBody, StockCountLinesBody, StockCountScanBody, StockCountPostBody. StockMovement gains source_number and reason. Error codes STOCK_ADJUSTMENT_NOT_FOUND, STOCK_COUNT_NOT_FOUND, UNIT_NOT_FOUND (404), STOCK_COUNT_OPEN, STOCK_COUNT_INCOMPLETE (409), STOCK_COUNT_PRODUCT_OUT_OF_SCOPE (422), ADJUSTMENT_SIGN_INVALID (400).

## 0.15.0

- I01 stock view: StockRow, StockList, StockListQuery (branch, category, subcategories, search, low_only); StockMovement, StockMovementList, StockMovementsQuery (drill-down), StockMovementType, StockState.

## 0.14.0

- C03 labels: UnitStatus, ProductUnit, ProductUnitList, ProductUnitsQuery (`GET /api/products/:id/units`).

## 0.13.0

- C02 products: Product, ProductList, ProductListQuery (search, category_id, include_subcategories, status), ProductLookupQuery, ProductCreateBody, ProductUpdateBody, ProductIdParams, EtaItemType, ProductStatus. Error codes PRODUCT_NOT_FOUND (404), PRODUCT_SKU_TAKEN, PRODUCT_BARCODE_TAKEN, PRODUCT_SERIAL_LOCKED, PRODUCT_CATEGORY_ARCHIVED (409).

## 0.12.0

- P04 legal and financing profile: `ShopProfile`, `ShopProfileUpdateBody`; error code `INSTALLMENTS_DISABLED` (403). `tax_registration_no` is edited through the profile, no longer through `PATCH /api/settings`.

## 0.11.0

- C01 categories: Category, CategoryList, CategoryCreateBody, CategoryUpdateBody, CategoryIdParams, CategoryArchiveBody, CategoryInUseDetail.

## 0.10.0

- T01 VAT engine: computeDocumentTax and returnLineTax (same results as the SQL engine on the golden cases), TaxClass schemas and bodies, TaxKind. ShopSettings gains installment_markup_vat, delivery_fee_tax_class_id, deposit_vat_timing. Error codes TAX_CLASS_NAME_TAKEN, TAX_CLASS_IN_USE, TAX_DISCOUNT_TOO_LARGE.

## 0.9.0

- P03 shop settings: ShopSettings, ShopSettingsUpdateBody, InstallmentPolicy(Body/List), Percent, InstallmentFrequency (adds daily), receipt fields, discount caps, credit weights, legal referral days. Error codes SETTINGS_INVALID, POLICY_INVALID, TAX_CLASS_NOT_FOUND, DISCOUNT_ABOVE_CAP.

## 0.8.1

- Merge EC-143 activation contracts with the shop task contracts; activation returns both naming conventions for existing callers.

## 0.8.0

- O02 staff management and password reset schemas/codes; invitation lookup includes the display login. BRANCH_REQUIRED maps to 400 for staff validation.

## 0.7.0

- O01 branch management, default safes, deactivation counts and branch error codes.

## 0.6.0

- P05 subscription states, usage, billing schemas, module keys, warning constant and structured limit errors. Shop-list rows include subscription end/state.

## 0.5.0

- P01 shop provisioning, platform shop administration, single-use invitations and the optional super-admin login flag.

## 0.4.2

- Access (EC-143): `EmployeeActiveSetBody` (`active`, `reason`), `EmployeeActiveSetResponse` and `EmployeeActiveSet` for `PUT /employees/:employeeId/active` (deactivate or reactivate an employee). Additive.

## 0.4.1

- Files (F14): `FilePurpose` (the 13 purposes of the `file_purpose` enum), `UploadFileRequest` (multipart text fields `purpose`, `entityType`, `entityId`), `FileResponse` (metadata only), `FileUrlResponse` (signed link and its expiry), `ListFilesQuery` (`entityType` + `entityId`), `FileListResponse`, and the path schema `FileIdParams`. Error codes `FILE_NOT_FOUND`, `FILE_PATH_INVALID`, `FILE_TOO_LARGE` (413) and `FILE_TYPE_NOT_ALLOWED` (415). Additive.

## 0.4.0

- Money (F12): `roundMoney` (one rule: half-up to 2 decimals), `addMoney`, `subtractMoney`, `sumMoney`, `compareMoney`, `multiplyMoney`, `percentOf`, `splitMoney` / `allocateMoney` (parts add back exactly, largest remainder), VAT `taxFromNet` / `taxFromGross` / `taxForLine` / `sumTaxLines` (tax rounded per line, totals are sums of lines) and `formatEgp` (Arabic and English). Inputs and outputs are decimal strings; the maths runs on `big.js` 7.0.1, the package's first runtime dependency besides zod (D31). Additive.

## 0.3.0

- Audit (F07): `AuditRow` gains `actorName` (the acting employee's full name, null for platform/service actions), so the owner's audit screen can show who did it without a separate employees endpoint. Additive for readers; servers must now send it.

## 0.2.0

- Access (F06): the employee id moves from the request bodies to the path (`EmployeeIdParams`, used by `PUT /employees/:employeeId/permissions` and `/branches`); `EmployeeBranchesAssignBody` gains a required `reason` (stored on the audit row), like the permission override. Breaking for these two bodies only; nothing used them in 0.1.0.

## 0.1.0

- First release: common types (Uuid, Money, dates, pagination, idempotency key), error codes and shape, roles, 61 permission keys with role defaults, schemas for auth (F04), access (F06), audit search (F07) and health (F08).
- Auth contract: login and forgot-password take `identifier` (+ `tenantSlug`, required for usernames); shops carry `tenantSlug`; `mustChangePassword` in login and me; change-password schema; password max 72 (bcrypt limit).
- select-shop response is now `{ user, shop }` only (no tokens; Supabase tokens carry no shop, D23).

## 0.11.0

- Add category schemas and category error codes.
