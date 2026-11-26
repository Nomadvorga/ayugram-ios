#ifndef APB_PYTHON_RUNTIME_QUEUE_BUDGET_H
#define APB_PYTHON_RUNTIME_QUEUE_BUDGET_H

#include <stddef.h>
#include <stdint.h>

#define APB_QUEUE_MAXIMUM_JOBS ((size_t)64)
#define APB_QUEUE_MAXIMUM_BYTES ((size_t)32 * 1024 * 1024)
#define APB_QUEUE_MAXIMUM_RESULT_UTF8_BYTES ((size_t)1024 * 1024)
// Reserve the largest temporary CPython Unicode backing (4 bytes per code
// point when one supplementary character forces 4-byte storage), its UTF-8
// cache, the NSString UTF-16 backing, and object overhead.
#define APB_QUEUE_MAXIMUM_RESULT_RETAINED_BYTES (7 * APB_QUEUE_MAXIMUM_RESULT_UTF8_BYTES + 512)

typedef struct {
    size_t maximum_jobs;
    size_t maximum_bytes;
    size_t result_retained_bytes;
    size_t outstanding_jobs;
    size_t outstanding_bytes;
} APBQueueBudget;

// Payload estimates are calculated from NSString UTF-16 code units by the
// Objective-C caller. Call these functions while holding that caller's lock.
static inline size_t apb_queue_payload_cost_begin(void) {
    return 256;
}

static inline int apb_queue_payload_cost_add_string(size_t *cost, size_t utf16_units) {
    if (!cost || *cost > SIZE_MAX - 64 || utf16_units > (SIZE_MAX - *cost - 64) / 4) {
        return 0;
    }
    *cost += utf16_units * 4 + 64;
    return 1;
}

// Add one Unicode scalar's UTF-8 width without overflowing or exceeding the
// caller's byte ceiling. The Objective-C runtime uses this before UTF-8 cache
// creation and NSString allocation; portable tests exercise the same helper.
static inline int apb_result_utf8_size_add(size_t *utf8_bytes,
                                          uint32_t code_point,
                                          size_t maximum_utf8_bytes) {
    if (!utf8_bytes || code_point > 0x10ffff) return 0;
    size_t width = code_point <= 0x7f ? 1 : code_point <= 0x7ff ? 2 : code_point <= 0xffff ? 3 : 4;
    if (width > maximum_utf8_bytes || *utf8_bytes > maximum_utf8_bytes - width) return 0;
    *utf8_bytes += width;
    return 1;
}

static inline void apb_queue_budget_init(APBQueueBudget *budget,
                                         size_t maximum_jobs,
                                         size_t maximum_bytes,
                                         size_t result_retained_bytes) {
    budget->maximum_jobs = maximum_jobs;
    budget->maximum_bytes = maximum_bytes;
    budget->result_retained_bytes = result_retained_bytes;
    budget->outstanding_jobs = 0;
    budget->outstanding_bytes = 0;
}

// The reservation includes the maximum retained result, not just queued
// input. It remains charged while executing and until its main-queue completion
// returns, so delayed delivery cannot create an unaccounted completion backlog.
static inline int apb_queue_budget_admit(APBQueueBudget *budget,
                                         size_t payload_bytes,
                                         size_t *outstanding_cost) {
    if (!budget || !outstanding_cost || payload_bytes > SIZE_MAX - budget->result_retained_bytes) {
        return 0;
    }
    size_t cost = payload_bytes + budget->result_retained_bytes;
    if (budget->outstanding_jobs >= budget->maximum_jobs ||
        cost > budget->maximum_bytes ||
        budget->outstanding_bytes > budget->maximum_bytes - cost) {
        return 0;
    }
    budget->outstanding_jobs += 1;
    budget->outstanding_bytes += cost;
    *outstanding_cost = cost;
    return 1;
}

// Call only after the completion has returned to its caller.
static inline int apb_queue_budget_complete(APBQueueBudget *budget, size_t outstanding_cost) {
    if (!budget || budget->outstanding_jobs == 0 || budget->outstanding_bytes < outstanding_cost) {
        return 0;
    }
    budget->outstanding_jobs -= 1;
    budget->outstanding_bytes -= outstanding_cost;
    return 1;
}

// Once execution has produced and released its temporary result, reduce the
// reservation to the actual bounded completion payload while retaining the
// job slot and input charge through main-thread delivery.
static inline int apb_queue_budget_adjust_result(APBQueueBudget *budget,
                                                 size_t *outstanding_cost,
                                                 size_t actual_result_bytes) {
    if (!budget || !outstanding_cost || actual_result_bytes > budget->result_retained_bytes ||
        *outstanding_cost < budget->result_retained_bytes) {
        return 0;
    }
    size_t reduction = budget->result_retained_bytes - actual_result_bytes;
    if (budget->outstanding_bytes < reduction) return 0;
    budget->outstanding_bytes -= reduction;
    *outstanding_cost -= reduction;
    return 1;
}

#endif
