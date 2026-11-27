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

static void test_only_the_executing_job_reserves_a_result(void) {
    APBQueueBudget budget;
    apb_queue_budget_init(&budget, 3, 1000, 400);
    size_t first_cost = 0;
    size_t second_cost = 0;
    assert(apb_queue_budget_admit(&budget, 100, &first_cost));
    assert(apb_queue_budget_admit(&budget, 100, &second_cost));
    // Queued jobs are charged their input only.
    assert(first_cost == 100 && second_cost == 100);
    assert(budget.outstanding_jobs == 2 && budget.outstanding_bytes == 200 && budget.payload_bytes == 200);

    assert(apb_queue_budget_begin_result(&budget, &first_cost));
    assert(first_cost == 500 && budget.outstanding_bytes == 600);

    // Finishing execution releases unused worst-case output headroom, but the
    // retained result, input and job slot stay charged until the completion
    // has been delivered.
    assert(apb_queue_budget_adjust_result(&budget, &first_cost, 300));
    assert(first_cost == 400 && budget.outstanding_bytes == 500);
    assert(budget.outstanding_jobs == 2);

    // The next job executes while the first result waits for main.
    assert(apb_queue_budget_begin_result(&budget, &second_cost));
    assert(second_cost == 500 && budget.outstanding_bytes == 900);
    assert(apb_queue_budget_adjust_result(&budget, &second_cost, 400));
    assert(budget.outstanding_bytes == 900);

    // Two undelivered results leave no room for a third execution: the worker
    // waits, it is not refused, and proceeds once a completion has returned.
    size_t third_cost = 0;
    assert(apb_queue_budget_admit(&budget, 100, &third_cost));
    assert(budget.outstanding_bytes == 1000);
    assert(!apb_queue_budget_begin_result(&budget, &third_cost));
    assert(third_cost == 100 && budget.outstanding_bytes == 1000);
    assert(apb_queue_budget_complete(&budget, first_cost, 100));
    assert(budget.outstanding_jobs == 2 && budget.outstanding_bytes == 600 && budget.payload_bytes == 200);
    assert(apb_queue_budget_begin_result(&budget, &third_cost));
    assert(third_cost == 500 && budget.outstanding_bytes == 1000);

    assert(!apb_queue_budget_complete(&budget, SIZE_MAX, 0));
    assert(!apb_queue_budget_complete(&budget, second_cost, second_cost + 1));
    assert(budget.outstanding_jobs == 2 && budget.outstanding_bytes == 1000);
}

static void test_admitted_inputs_always_leave_one_result_reservation(void) {
    APBQueueBudget budget;
    apb_queue_budget_init(&budget, 64, 1000, 400);
    size_t cost = 0;
    // Inputs may fill everything except one result reservation.
    assert(!apb_queue_budget_admit(&budget, 601, &cost));
    assert(apb_queue_budget_admit(&budget, 600, &cost));
    assert(cost == 600);
    size_t rejected = 0;
    assert(!apb_queue_budget_admit(&budget, 1, &rejected));
    assert(apb_queue_budget_admit(&budget, 0, &rejected));
    assert(apb_queue_budget_complete(&budget, rejected, 0));
    // So the admitted job can execute whenever no other result is outstanding.
    assert(apb_queue_budget_begin_result(&budget, &cost));
    assert(cost == 1000 && budget.outstanding_bytes == 1000);
    assert(apb_queue_budget_adjust_result(&budget, &cost, 0));
    assert(apb_queue_budget_complete(&budget, cost, 600));
    assert(budget.outstanding_jobs == 0 && budget.outstanding_bytes == 0 && budget.payload_bytes == 0);

    // An executing job's reservation does not block admission of small inputs,
    // but the total never exceeds the ceiling.
    assert(apb_queue_budget_admit(&budget, 100, &cost));
    assert(apb_queue_budget_begin_result(&budget, &cost));
    size_t queued = 0;
    assert(apb_queue_budget_admit(&budget, 500, &queued));
    assert(budget.outstanding_bytes == 1000);
    assert(!apb_queue_budget_admit(&budget, 1, &rejected));
}

static void test_job_limit_and_saturated_arithmetic(void) {
    APBQueueBudget budget;
    apb_queue_budget_init(&budget, 1, 1000, 400);
    size_t cost = 0;
    assert(apb_queue_budget_admit(&budget, 10, &cost));
    assert(!apb_queue_budget_admit(&budget, 0, &cost));
    assert(!apb_queue_budget_admit(&budget, SIZE_MAX, &cost));
    assert(apb_queue_budget_complete(&budget, 10, 10));

    // A result reservation larger than the ceiling admits nothing.
    apb_queue_budget_init(&budget, 4, 100, 400);
    assert(!apb_queue_budget_admit(&budget, 0, &cost));
    assert(!apb_queue_budget_begin_result(&budget, &cost));
    assert(budget.outstanding_jobs == 0 && budget.outstanding_bytes == 0);
}

static void test_small_callbacks_fill_the_job_limit_not_the_byte_limit(void) {
    APBQueueBudget budget;
    apb_queue_budget_init(&budget,
                          APB_QUEUE_MAXIMUM_JOBS,
                          APB_QUEUE_MAXIMUM_BYTES,
                          APB_QUEUE_MAXIMUM_RESULT_RETAINED_BYTES);
    size_t callback_cost = apb_queue_payload_cost_begin();
    assert(apb_queue_payload_cost_add_string(&callback_cost, 200));
    size_t costs[APB_QUEUE_MAXIMUM_JOBS];
    for (size_t index = 0; index < APB_QUEUE_MAXIMUM_JOBS; index++) {
        assert(apb_queue_budget_admit(&budget, callback_cost, &costs[index]));
    }
    size_t rejected = 0;
    assert(!apb_queue_budget_admit(&budget, callback_cost, &rejected));
    assert(budget.outstanding_bytes == APB_QUEUE_MAXIMUM_JOBS * callback_cost);
    assert(apb_queue_budget_begin_result(&budget, &costs[0]));
}

static void test_maximum_payloads_admit_once_with_result_headroom(void) {
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
    assert(!apb_queue_budget_admit(&budget, source_cost, &reservation));
    assert(apb_queue_budget_begin_result(&budget, &reservation));
    assert(reservation < APB_QUEUE_MAXIMUM_BYTES);
    assert(budget.outstanding_jobs == 1);
    assert(apb_queue_budget_complete(&budget, reservation, source_cost));
    assert(budget.outstanding_jobs == 0 && budget.outstanding_bytes == 0);

    // The largest callback the SDK reads (6,000,000 characters of JSON) is
    // admitted while a small job executes, and only one of them at a time.
    size_t small_cost = apb_queue_payload_cost_begin();
    assert(apb_queue_payload_cost_add_string(&small_cost, 200));
    size_t small = 0;
    assert(apb_queue_budget_admit(&budget, small_cost, &small));
    assert(apb_queue_budget_begin_result(&budget, &small));
    size_t callback_cost = apb_queue_payload_cost_begin();
    assert(apb_queue_payload_cost_add_string(&callback_cost, 6000000));
    assert(apb_queue_payload_cost_add_string(&callback_cost, 64));
    size_t callback = 0;
    assert(apb_queue_budget_admit(&budget, callback_cost, &callback));
    assert(!apb_queue_budget_admit(&budget, callback_cost, &reservation));
    assert(budget.outstanding_bytes <= APB_QUEUE_MAXIMUM_BYTES);
}

int main(void) {
    test_payload_cost_and_overflow();
    test_result_utf8_limit_counts_all_unicode_widths();
    test_only_the_executing_job_reserves_a_result();
    test_admitted_inputs_always_leave_one_result_reservation();
    test_job_limit_and_saturated_arithmetic();
    test_small_callbacks_fill_the_job_limit_not_the_byte_limit();
    test_maximum_payloads_admit_once_with_result_headroom();
    puts("APBPythonRuntimeQueueBudgetTests: PASS");
    return 0;
}
