#define PERL_NO_GET_CONTEXT
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

/*
 * Some definitions that were copied verbatim froms threads.xs, these need to be looked at
 */

#ifdef WIN32
#  undef setjmp
#  if !defined(__BORLANDC__)
#    define setjmp(x) _setjmp(x)
#  endif
#endif
//XXX

#ifdef WIN32
#  include <windows.h>
/* Supposed to be in Winbase.h */
#  ifndef STACK_SIZE_PARAM_IS_A_RESERVATION
#    define STACK_SIZE_PARAM_IS_A_RESERVATION 0x00010000
#  endif
#  include <win32thread.h>
#else
#  ifdef OS2
typedef perl_os_thread pthread_t;
#  else
#    include <pthread.h>
#  endif
#  include <thread.h>
#  define PERL_THREAD_SETSPECIFIC(k,v) pthread_setspecific(k,v)
#  ifdef OLD_PTHREADS_API
#    define PERL_THREAD_DETACH(t) pthread_detach(&(t))
#  else
#    define PERL_THREAD_DETACH(t) pthread_detach((t))
#  endif
#endif
#if !defined(HAS_GETPAGESIZE) && defined(I_SYS_PARAM)
#  include <sys/param.h>
#endif

#ifndef WIN32
static int S_set_sigmask(sigset_t *);
#endif

/*
 * struct message
 */

enum node_type { STRING = 1, STORABLE = 2 };

typedef struct {
	enum node_type type;
	struct {
		char* ptr;
		STRLEN length;
	} string;
} message;

static SV* S_message_get_sv(pTHX_ message* message) {
	SV* stored = newSV_type(SVt_PV);
	SvPVX(stored) = message->string.ptr;
	SvLEN(stored) = SvCUR(stored) = message->string.length;
	SvPOK_only(stored);
	return stored;
}

#define message_get_sv(message) S_message_get_sv(aTHX_ message)

static void S_message_set_sv(pTHX_ message* message, SV* value, enum node_type type) {
	message->type = type;
	char* string = SvPV(value, message->string.length);
	message->string.ptr = savepvn(string, message->string.length);
}

#define message_set_sv(message, value, type) S_message_set_sv(aTHX_ message, value, type)

static void S_message_store_value(pTHX_ message* message, SV* value) {
	dSP;
	ENTER;
	SAVETMPS;
	sv_setiv(save_scalar(gv_fetchpv("Storable::Deparse", TRUE | GV_ADDMULTI, SVt_PV)), 1);
	PUSHMARK(SP);
	PUSHs(sv_2mortal(newRV_inc(value)));
	PUTBACK;
	call_pv("Storable::mstore", G_SCALAR);
	SPAGAIN;
	message_set_sv(message, POPs, STORABLE);
	FREETMPS;
	LEAVE;
}

#define message_store_value(message, value) S_message_store_value(aTHX_ message, value)

static void S_message_pull_stack(pTHX_ message* message) {
	dSP; dMARK;
	if (SP == MARK) {
		if (!SvOK(*MARK) || SvROK(*MARK) || (SvPOK(*MARK) && SvUTF8(*MARK)))
			message_store_value(message, *MARK);
		else
			message_set_sv(message, *MARK, STRING);
	}
	else {
		SV* list = sv_2mortal((SV*)av_make(SP - MARK + 1, MARK));
		message_store_value(message, list);
	}
}

#define message_pull_stack(message) STMT_START { PUTBACK; S_message_pull_stack(aTHX_ message); SPAGAIN; } STMT_END

static void S_message_push_stack(pTHX_ message* message) {
	dSP;

	switch(message->type) {
		case STRING:
			PUSHs(sv_2mortal(message_get_sv(message)));
			break;
		case STORABLE: {
			ENTER;
			sv_setiv(save_scalar(gv_fetchpv("Storable::Eval", TRUE | GV_ADDMULTI, SVt_PV)), 1);
			PUSHMARK(SP);
			XPUSHs(sv_2mortal(message_get_sv(message)));
			PUTBACK;
			call_pv("Storable::thaw", G_SCALAR);
			SPAGAIN;
			LEAVE;
			AV* values = (AV*)SvRV(POPs);

			if (GIMME_V == G_SCALAR) {
				SV** ret = av_fetch(values, 0, FALSE);
				PUSHs(ret ? *ret : &PL_sv_undef);
			}
			else if (GIMME_V == G_ARRAY) {
				UV count = av_len(values) + 1;
				Copy(AvARRAY(values), SP + 1, count, SV*);
				SP += count;
			}
			break;
		}
		default:
			Perl_croak(aTHX_ "Type %d is not yet implemented", message->type);
	}

	PUTBACK;
}

#define message_push_stack(values) STMT_START { PUTBACK; S_message_push_stack(aTHX_ (values)); SPAGAIN; } STMT_END

static void message_destroy(message* message) {
	switch(message->type) {
		case STRING:
		case STORABLE:
			Safefree(message->string.ptr);
			break;
		default:
			warn("Unknown type in queue\n");
	}
	Zero(message, 1, message);
}

/*
 * Message queues
 */

typedef struct queue_node {
	message message;
	struct queue_node* next;
} queue_node;

static void node_unshift(queue_node** position, queue_node* new_node) {
	new_node->next = *position;
	*position = new_node;
}

static queue_node* node_shift(queue_node** position) {
	queue_node* ret = *position;
	*position = (*position)->next;
	return ret;
}

static void node_push(queue_node** end, queue_node* new_node) {
	queue_node** cur = end;
	while(*cur)
		cur = &(*cur)->next;
	*end = *cur = new_node;
	new_node->next = NULL;
}

typedef struct {
	perl_mutex mutex;
	perl_cond condvar;
	queue_node* front;
	queue_node* back;
	queue_node* reserve;
} message_queue;

static message_queue* queue_new() {
	message_queue* queue;
	Newxz(queue, 1, message_queue);
	MUTEX_INIT(&queue->mutex);
	COND_INIT(&queue->condvar);
	return queue;
}

static void queue_enqueue(message_queue* queue, message* message_) {
	MUTEX_LOCK(&queue->mutex);

	queue_node* new_entry;
	if (queue->reserve) {
		new_entry = node_shift(&queue->reserve);
	}
	else
		Newx(new_entry, 1, queue_node);

	Copy(message_, &new_entry->message, 1, message);
	new_entry->next = NULL;

	node_push(&queue->back, new_entry);
	if (queue->front == NULL)
		queue->front = queue->back;

	COND_SIGNAL(&queue->condvar);
	MUTEX_UNLOCK(&queue->mutex);
}

static void queue_dequeue(message_queue* queue, message* input) {
	MUTEX_LOCK(&queue->mutex);

	while (!queue->front)
		COND_WAIT(&queue->condvar, &queue->mutex);

	queue_node* front = node_shift(&queue->front);
	Copy(&front->message, input, 1, message);
	node_unshift(&queue->reserve, front);

	if (queue->front == NULL)
		queue->back = NULL;

	MUTEX_UNLOCK(&queue->mutex);
}

static bool queue_dequeue_nb(message_queue* queue, message* input) {
	MUTEX_LOCK(&queue->mutex);

	if(queue->front) {
		queue_node* front = node_shift(&queue->front);
		Copy(&front->message, input, 1, message);
		node_unshift(&queue->reserve, front);

		if (queue->front == NULL)
			queue->back = NULL;

		MUTEX_UNLOCK(&queue->mutex);
		return TRUE;
	}
	else {
		MUTEX_UNLOCK(&queue->mutex);
		return FALSE;
	}
}

/*
 * Threads implementation itself
 */

static struct {
	perl_mutex lock;
	bool inited;
	UV count;
} global;

typedef struct {
	message_queue* queue;

#ifdef WIN32
	DWORD  thr;                 /* OS's idea if thread id */
	HANDLE handle;              /* OS's waitable handle */
#else
	pthread_t thr;              /* OS's handle for the thread */
	sigset_t initial_sigmask;   /* Thread wakes up with signals blocked */
#endif
} mthread;

void boot_DynaLoader(pTHX_ CV* cv);

static void xs_init(pTHX) {
	dXSUB_SYS;
	newXS((char*)"DynaLoader::boot_DynaLoader", boot_DynaLoader, (char*)__FILE__);
}

static const char* argv[] = {"", "-e", "threads::lite::_run()"};
static int argc = sizeof argv / sizeof *argv;

static void* run_thread(void* arg) {
	MUTEX_LOCK(&global.lock);
	++global.count;
	MUTEX_UNLOCK(&global.lock);

	mthread* thread = (mthread*) arg;
	PerlInterpreter* my_perl = perl_alloc();
	perl_construct(my_perl);
	PL_exit_flags |= PERL_EXIT_DESTRUCT_END;

	perl_parse(my_perl, xs_init, argc, (char**)argv, NULL);
	S_set_sigmask(&thread->initial_sigmask);

	SV* thread_sv = newSV_type(SVt_PV);
	SvPVX(thread_sv) = (char*) thread;
	SvCUR(thread_sv) = sizeof(mthread);
	SvLEN(thread_sv) = 0;
	SvPOK_only(thread_sv);
	SvREADONLY_on(thread_sv);
	hv_store(PL_modglobal, "thread::lite::self", 18, thread_sv, 0);

	load_module(PERL_LOADMOD_NOIMPORT, newSVpv("threads::lite", 0), NULL, NULL);

	dSP; dAXMARK;
	ENTER;

	PUSHMARK(SP);
	call_pv("threads::lite::_get_runtime", G_SCALAR);
	SPAGAIN;

	SV* call = POPs;
	PUSHMARK(SP);
	PUTBACK;
	call_sv(call, G_VOID|G_DISCARD|G_EVAL);
	FREETMPS;

	LEAVE;

	MUTEX_LOCK(&global.lock);
	--global.count;
	MUTEX_UNLOCK(&global.lock);
	return NULL;
}

#ifndef WIN32
/* Block most signals for calling thread, setting the old signal mask to
 * oldmask, if it is not NULL */
static int S_block_most_signals(sigset_t *oldmask)
{
	sigset_t newmask;

	sigfillset(&newmask);
	/* Don't block certain "important" signals (stolen from mg.c) */
#ifdef SIGILL
	sigdelset(&newmask, SIGILL);
#endif
#ifdef SIGBUS
	sigdelset(&newmask, SIGBUS);
#endif
#ifdef SIGSEGV
	sigdelset(&newmask, SIGSEGV);
#endif

#if defined(VMS)
	/* no per-thread blocking available */
	return sigprocmask(SIG_BLOCK, &newmask, oldmask);
#else
	return pthread_sigmask(SIG_BLOCK, &newmask, oldmask);
#endif /* VMS */
}

/* Set the signal mask for this thread to newmask */
static int S_set_sigmask(sigset_t *newmask)
{
#if defined(VMS)
	return sigprocmask(SIG_SETMASK, newmask, NULL);
#else
	return pthread_sigmask(SIG_SETMASK, newmask, NULL);
#endif /* VMS */
}
#endif /* WIN32 */

static mthread* create_thread(IV stack_size) {
	mthread* thread;
	Newxz(thread, 1, mthread);
	thread->queue = queue_new();
#ifdef WIN32
	thread->handle = CreateThread(NULL,
								  (DWORD)stack_size,
								  run_thread,
								  (LPVOID)thread,
								  STACK_SIZE_PARAM_IS_A_RESERVATION,
								  &thread->thr);
#else
	int rc_stack_size = 0;
	int rc_thread_create = 0;

	S_block_most_signals(&thread->initial_sigmask);

	static pthread_attr_t attr;
	static int attr_inited = 0;
	static int attr_joinable = PTHREAD_CREATE_JOINABLE;
	if (! attr_inited) {
		pthread_attr_init(&attr);
		attr_inited = 1;
	}

#  ifdef PTHREAD_ATTR_SETDETACHSTATE
	/* Threads start out joinable */
	PTHREAD_ATTR_SETDETACHSTATE(&attr, attr_joinable);
#  endif

#  ifdef _POSIX_THREAD_ATTR_STACKSIZE
	/* Set thread's stack size */
	if (stack_size > 0) {
		rc_stack_size = pthread_attr_setstacksize(&attr, (size_t)stack_size);
	}
#  endif

	/* Create the thread */
	if (! rc_stack_size) {
#  ifdef OLD_PTHREADS_API
		rc_thread_create = pthread_create(&thread->thr, attr, run_thread, (void *)thread);
#  else
#	if defined(HAS_PTHREAD_ATTR_SETSCOPE) && defined(PTHREAD_SCOPE_SYSTEM)
		pthread_attr_setscope(&attr, PTHREAD_SCOPE_SYSTEM);
#	endif
		rc_thread_create = pthread_create(&thread->thr, &attr, run_thread, (void *)thread);
#  endif
	}
	/* Now it's safe to accept signals, since we're in our own interpreter's
	 * context and we have created the thread.
	 */
	S_set_sigmask(&thread->initial_sigmask);
#endif
	return thread;
}

MODULE = threads::lite             PACKAGE = threads::lite

PROTOTYPES: DISABLED

BOOT:
	if (!global.inited) {
		MUTEX_INIT(&global.lock);
		global.inited = TRUE;
		global.count = 1;
	}


SV*
_create(object)
	SV* object;
	CODE:
		mthread* thread = create_thread(65536);
		RETVAL = newRV_noinc(newSVuv(PTR2UV(thread)));
		sv_bless(RETVAL, gv_stashpv("threads::lite::tid", FALSE));
	OUTPUT:
		RETVAL

void
_receive()
	PPCODE:
		SV** self_sv = hv_fetch(PL_modglobal, "thread::lite::self", 18, FALSE);
		if (!self_sv)
			Perl_croak(aTHX_ "Can't find self thread object!");
		mthread* thread = (mthread*)SvPV_nolen(*self_sv);
		message message;
		queue_dequeue(thread->queue, &message);
		message_push_stack(&message);
	
void
_receive_nb()
	PPCODE:
		SV** self_sv = hv_fetch(PL_modglobal, "thread::lite::self", 18, FALSE);
		if (!self_sv)
			Perl_croak(aTHX_ "Can't find self thread object!");
		mthread* thread = (mthread*)SvPV_nolen(*self_sv);
		message message;
		if (queue_dequeue_nb(thread->queue, &message))
			 message_push_stack(&message);
		else
			XSRETURN_EMPTY;

void
_load_module(module)
	SV* module;
	CODE:
		load_module(PERL_LOADMOD_NOIMPORT, module, NULL, NULL);

MODULE = threads::lite             PACKAGE = threads::lite::tid

PROTOTYPES: DISABLED

void
send(object, ...)
	SV* object;
	CODE:
		if (!sv_isobject(object) || !sv_derived_from(object, "threads::lite::tid"))
			Perl_croak(aTHX_ "Something is very wrong, this is not a magic thread object\n");
		if (items == 1)
			Perl_croak(aTHX_ "Can't send an empty list\n");
		message_queue* queue = (INT2PTR(mthread*, SvUV(SvRV(object))))->queue;
		message message;
		PUSHMARK(MARK + 2);
		message_pull_stack(&message);
		queue_enqueue(queue, &message);

