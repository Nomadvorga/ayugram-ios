#include "APBPythonRuntimeQueueBudget.h"

#ifdef NDEBUG
#undef NDEBUG
#endif
#include <assert.h>
#include <stdint.h>
#include <stdio.h>

static void test_payload_cost_and_overflow(void) {
    size_t cost = apb_queue_payload_cost_begin();
    assert(apb_queue_payload_cost_add_string(&cost, 1));
    assert(cost == 324);
    assert(apb_queue_payload_cost_add_string(&cost, 2));
    assert(cost == 396);

    cost = SIZE_MAX - 32;
    assert(!apb_queue_payload_cost_add_string(&cost, 1));
}

static void test_result_utf8_limit_counts_all_unicode_widths(void) {
    size_t bytes = 0;
    assert(apb_result_utf8_size_add(&bytes, 'A', 10));
    assert(apb_result_utf8_size_add(&bytes, 0x7ff, 10));
    assert(apb_result_utf8_size_add(&bytes, 0x800, 10));
    assert(apb_result_utf8_size_add(&bytes, 0x1f600, 10));
    assert(bytes == 10);
    assert(!apb_result_utf8_size_add(&bytes, 'x', 10));
    assert(bytes == 10);
    assert(!apb_result_utf8_size_add(&bytes, 0x110000, 20));
    assert(!apb_result_utf8_size_add(&bytes, 'x', 0));
    assert(bytes == 10);
}

static void test_result_reservation_stays_charged_through_delivery(void) {
    APBQueueBudget budget;
    apb_queue_budget_init(&budget, 2, 1000, 400);
    size_t first_cost = 0;
    size_t second_cost = 0;
    assert(apb_queue_budget_admit(&budget, 100, &first_cost));
    assert(apb_queue_budget_admit(&budget, 100, &second_cost));
    assert(first_cost == 500 && second_cost == 500);
    assert(budget.outstanding_jobs == 2 && budget.outstanding_bytes == 1000);

    // Dequeue/execution does not release a reservation. A third job is still
    // rejected while both completions have not yet been delivered.
    size_t rejected_cost = 0;
    assert(!apb_queue_budget_admit(&budget, 1, &rejected_cost));
    assert(budget.outstanding_jobs == 2 && budget.outstanding_bytes == 1000);

    // Finishing execution releases unused worst-case output headroom, but the
    // retained result and job remain charged until the completion is delivered.
    assert(apb_queue_budget_adjust_result(&budget, &first_cost, 300));
    assert(first_cost == 400 && budget.outstanding_bytes == 900);
    assert(!apb_queue_budget_admit(&budget, 1, &rejected_cost));

    assert(apb_queue_budget_complete(&budget, first_cost));
    assert(budget.outstanding_jobs == 1 && budget.outstanding_bytes == 500);
    assert(apb_queue_budget_admit(&budget, 100, &rejected_cost));
    assert(rejected_cost == 500);
    assert(!apb_queue_budget_complete(&budget, SIZE_MAX));
    assert(budget.outstanding_jobs == 2 && budget.outstanding_bytes == 1000);
}

static void test_job_and_byte_limits_and_saturated_arithmetic(void) {
    APBQueueBudget budget;
    apb_queue_budget_init(&budget, 1, 1000, 400);
    size_t cost = 0;
    assert(apb_queue_budget_admit(&budget, 600, &cost));
    assert(cost == 1000);
    assert(!apb_queue_budget_admit(&budget, 0, &cost));
    assert(!apb_queue_budget_admit(&budget, SIZE_MAX, &cost));
    assert(apb_queue_budget_complete(&budget, 1000));

    apb_queue_budget_init(&budget, 64, 1000, 400);
    assert(!apb_queue_budget_admit(&budget, 601, &cost));
    assert(budget.outstanding_jobs == 0 && budget.outstanding_bytes == 0);
}

static void test_maximum_source_admits_once_with_result_headroom(void) {
    APBQueueBudget budget;
    apb_queue_budget_init(&budget,
                          APB_QUEUE_MAXIMUM_JOBS,
                          APB_QUEUE_MAXIMUM_BYTES,
                          APB_QUEUE_MAXIMUM_RESULT_RETAINED_BYTES);
    size_t source_cost = apb_queue_payload_cost_begin();
    assert(apb_queue_payload_cost_add_string(&source_cost, 4 * 1024 * 1024));
    assert(apb_queue_payload_cost_add_string(&source_cost, 16));
    size_t reservation = 0;
    assert(apb_queue_budget_admit(&budget, source_cost, &reservation));
    assert(reservation < APB_QUEUE_MAXIMUM_BYTES);
    assert(!apb_queue_budget_admit(&budget, source_cost, &reservation));
    assert(budget.outstanding_jobs == 1);
    assert(apb_queue_budget_complete(&budget, reservation));
    assert(budget.outstanding_jobs == 0 && budget.outstanding_bytes == 0);
}

int main(void) {
    test_payload_cost_and_overflow();
    test_result_utf8_limit_counts_all_unicode_widths();
    test_result_reservation_stays_charged_through_delivery();
    test_job_and_byte_limits_and_saturated_arithmetic();
    test_maximum_source_admits_once_with_result_headroom();
    puts("APBPythonRuntimeQueueBudgetTests: PASS");
    return 0;
}
