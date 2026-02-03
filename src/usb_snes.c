/*
 *  GRUB USB SNES Gamepad - Based on working usb_keyboard.c
 *
 *  The KEY difference: We accept HID devices with ANY subclass/protocol,
 *  not just keyboards (subclass=1, protocol=1).
 *
 *  This uses the SAME initialization sequence as usb_keyboard.c which
 *  is proven to work.
 */

#include <grub/term.h>
#include <grub/time.h>
#include <grub/misc.h>
#include <grub/usb.h>
#include <grub/dl.h>

GRUB_MOD_LICENSE ("GPLv3+");

/* HID Protocol constants - same as usb_keyboard.c */
#define USB_HID_SET_IDLE        0x0A
#define USB_HID_SET_PROTOCOL    0x0B

/* SNES Report constants */
#define SNES_REPORT_SIZE 8
#define AXIS_CENTER      0x7F
#define AXIS_THRESHOLD   0x40

/* Maximum gamepads */
#define MAX_GAMEPADS 8

/* Supported devices - add your controller here */
static struct {
    grub_uint16_t vid;
    grub_uint16_t pid;
} supported_devices[] = {
    {0x0810, 0xe501},   /* Generic Chinese SNES */
    {0x0079, 0x0011},   /* DragonRise */
    {0x0583, 0x2060},   /* iBuffalo */
    {0x2dc8, 0x9018},   /* 8BitDo SN30 */
    {0x12bd, 0xd015},   /* Generic 2-pack */
    {0x1a34, 0x0802},   /* USB Gamepad */
    {0x0810, 0x0001},   /* Generic USB */
    {0x0079, 0x0006},   /* DragonRise v2 */
    {0x046d, 0xc218},   /* Logitech F510 (for testing) */
    {0, 0}              /* End marker */
};

struct grub_usb_snes_data
{
    grub_usb_device_t usbdev;
    int interfno;
    struct grub_usb_desc_endp *endp;
    grub_usb_transfer_t transfer;
    grub_uint8_t report[SNES_REPORT_SIZE];
    grub_uint8_t prev_report[SNES_REPORT_SIZE];
    int dead;
    int key_queue[32];
    int key_queue_head;
    int key_queue_tail;
    int key_queue_count;
};

static struct grub_term_input grub_usb_snes_terms[MAX_GAMEPADS];

/* Key queue functions */
static void
key_queue_push(struct grub_usb_snes_data *data, int key)
{
    if (data->key_queue_count >= 32 || key == GRUB_TERM_NO_KEY)
        return;
    data->key_queue[data->key_queue_tail] = key;
    data->key_queue_tail = (data->key_queue_tail + 1) % 32;
    data->key_queue_count++;
}

static int
key_queue_pop(struct grub_usb_snes_data *data)
{
    if (data->key_queue_count <= 0)
        return GRUB_TERM_NO_KEY;
    int key = data->key_queue[data->key_queue_head];
    data->key_queue_head = (data->key_queue_head + 1) % 32;
    data->key_queue_count--;
    return key;
}

/* Check if device is in our supported list */
static int
is_supported_device(grub_uint16_t vid, grub_uint16_t pid)
{
    int i;
    for (i = 0; supported_devices[i].vid != 0; i++)
    {
        if (supported_devices[i].vid == vid &&
            supported_devices[i].pid == pid)
            return 1;
    }
    return 0;
}

/* Parse SNES HID report and generate keys */
static void
parse_snes_report(struct grub_usb_snes_data *data)
{
    grub_uint8_t *prev = data->prev_report;
    grub_uint8_t *curr = data->report;

    /* D-Pad from X/Y axes (bytes 0 and 1)
     * 0x00 = left/up, 0x7F = center, 0xFF = right/down */

    int prev_up    = (prev[1] < AXIS_CENTER - AXIS_THRESHOLD);
    int prev_down  = (prev[1] > AXIS_CENTER + AXIS_THRESHOLD);
    int prev_left  = (prev[0] < AXIS_CENTER - AXIS_THRESHOLD);
    int prev_right = (prev[0] > AXIS_CENTER + AXIS_THRESHOLD);

    int curr_up    = (curr[1] < AXIS_CENTER - AXIS_THRESHOLD);
    int curr_down  = (curr[1] > AXIS_CENTER + AXIS_THRESHOLD);
    int curr_left  = (curr[0] < AXIS_CENTER - AXIS_THRESHOLD);
    int curr_right = (curr[0] > AXIS_CENTER + AXIS_THRESHOLD);

    /* Generate key on press (not release) */
    if (!prev_up && curr_up)
        key_queue_push(data, GRUB_TERM_KEY_UP);
    if (!prev_down && curr_down)
        key_queue_push(data, GRUB_TERM_KEY_DOWN);
    if (!prev_left && curr_left)
        key_queue_push(data, GRUB_TERM_KEY_LEFT);
    if (!prev_right && curr_right)
        key_queue_push(data, GRUB_TERM_KEY_RIGHT);

    /* Buttons from byte 4 (and sometimes byte 5)
     * Common SNES mapping:
     * Bit 0: X, Bit 1: A, Bit 2: B, Bit 3: Y
     * Bit 4: L, Bit 5: R, Bit 6: Select, Bit 7: Start */

    grub_uint8_t prev_btns = prev[4];
    grub_uint8_t curr_btns = curr[4];

    /* A button (bit 1) or B button (bit 2) -> Enter */
    if ((!(prev_btns & 0x02) && (curr_btns & 0x02)) ||
        (!(prev_btns & 0x04) && (curr_btns & 0x04)))
        key_queue_push(data, '\r');

    /* Start button (bit 7) -> Enter */
    if (!(prev_btns & 0x80) && (curr_btns & 0x80))
        key_queue_push(data, '\r');

    /* Select button (bit 6) -> Escape */
    if (!(prev_btns & 0x40) && (curr_btns & 0x40))
        key_queue_push(data, GRUB_TERM_ESC);

    /* X button (bit 0) -> 'e' (edit in GRUB) */
    if (!(prev_btns & 0x01) && (curr_btns & 0x01))
        key_queue_push(data, 'e');

    /* Y button (bit 3) -> 'c' (command line in GRUB) */
    if (!(prev_btns & 0x08) && (curr_btns & 0x08))
        key_queue_push(data, 'c');

    /* L button (bit 4) -> Page Up */
    if (!(prev_btns & 0x10) && (curr_btns & 0x10))
        key_queue_push(data, GRUB_TERM_KEY_PPAGE);

    /* R button (bit 5) -> Page Down */
    if (!(prev_btns & 0x20) && (curr_btns & 0x20))
        key_queue_push(data, GRUB_TERM_KEY_NPAGE);

    grub_dprintf("usb_snes", "Report: %02x %02x %02x %02x %02x %02x %02x %02x\n",
                 curr[0], curr[1], curr[2], curr[3],
                 curr[4], curr[5], curr[6], curr[7]);
}

static int
grub_usb_snes_getkey(struct grub_term_input *term)
{
    struct grub_usb_snes_data *data = term->data;
    grub_size_t actual;
    grub_usb_err_t err;

    if (data->dead)
        return GRUB_TERM_NO_KEY;

    /* Check for pending keys in queue */
    if (data->key_queue_count > 0)
        return key_queue_pop(data);

    /* Poll USB transfer */
    err = grub_usb_check_transfer(data->transfer, &actual);

    if (err == GRUB_USB_ERR_WAIT)
        return GRUB_TERM_NO_KEY;

    if (err == GRUB_USB_ERR_NONE && actual >= 1)
    {
        /* Parse the report */
        parse_snes_report(data);

        /* Save current as previous */
        grub_memcpy(data->prev_report, data->report, SNES_REPORT_SIZE);
    }

    /* Restart transfer */
    data->transfer = grub_usb_bulk_read_background(
        data->usbdev,
        data->endp,
        sizeof(data->report),
        (char *)data->report);

    if (!data->transfer)
    {
        grub_printf("usb_snes: Transfer failed, device stopped\n");
        data->dead = 1;
        return GRUB_TERM_NO_KEY;
    }

    return key_queue_pop(data);
}

static int
grub_usb_snes_getkeystatus(struct grub_term_input *term __attribute__((unused)))
{
    return 0;
}

static void
grub_usb_snes_detach(grub_usb_device_t usbdev,
                     int config __attribute__((unused)),
                     int interface __attribute__((unused)))
{
    unsigned i;
    for (i = 0; i < MAX_GAMEPADS; i++)
    {
        struct grub_usb_snes_data *data = grub_usb_snes_terms[i].data;
        if (!data || data->usbdev != usbdev)
            continue;

        if (data->transfer)
            grub_usb_cancel_transfer(data->transfer);

        grub_term_unregister_input(&grub_usb_snes_terms[i]);
        grub_free((char *)grub_usb_snes_terms[i].name);
        grub_usb_snes_terms[i].name = NULL;
        grub_free(data);
        grub_usb_snes_terms[i].data = NULL;
    }
}

static int
grub_usb_snes_attach(grub_usb_device_t usbdev, int configno, int interfno)
{
    unsigned curnum;
    struct grub_usb_snes_data *data;
    struct grub_usb_desc_endp *endp = NULL;
    int j;

    grub_dprintf("usb_snes", "Checking device VID=%04x PID=%04x\n",
                 usbdev->descdev.vendorid, usbdev->descdev.prodid);

    /* Check if this device is in our supported list */
    if (!is_supported_device(usbdev->descdev.vendorid,
                             usbdev->descdev.prodid))
    {
        grub_dprintf("usb_snes", "Device not in supported list\n");
        return 0;
    }

    grub_dprintf("usb_snes", "Supported device found!\n");

    /* Find free slot */
    for (curnum = 0; curnum < MAX_GAMEPADS; curnum++)
        if (!grub_usb_snes_terms[curnum].data)
            break;

    if (curnum == MAX_GAMEPADS)
    {
        grub_dprintf("usb_snes", "No free slots\n");
        return 0;
    }

    /* Find INTERRUPT IN endpoint - CRITICAL! */
    for (j = 0; j < usbdev->config[configno].interf[interfno].descif->endpointcnt; j++)
    {
        endp = &usbdev->config[configno].interf[interfno].descendp[j];

        /* Must be INTERRUPT type and IN direction (bit 7 set) */
        if ((endp->endp_addr & 128) &&
            grub_usb_get_ep_type(endp) == GRUB_USB_EP_INTERRUPT)
            break;
    }

    if (j == usbdev->config[configno].interf[interfno].descif->endpointcnt)
    {
        grub_dprintf("usb_snes", "No interrupt IN endpoint found\n");
        return 0;
    }

    grub_dprintf("usb_snes", "Found interrupt endpoint %d\n", j);

    /* Allocate data structure */
    data = grub_malloc(sizeof(*data));
    if (!data)
    {
        grub_print_error();
        return 0;
    }

    grub_memset(data, 0, sizeof(*data));
    data->usbdev = usbdev;
    data->interfno = interfno;
    data->endp = endp;
    data->dead = 0;

    /* Initialize previous report to centered state */
    data->prev_report[0] = AXIS_CENTER;
    data->prev_report[1] = AXIS_CENTER;
    data->prev_report[2] = AXIS_CENTER;
    data->prev_report[3] = AXIS_CENTER;
    data->prev_report[4] = 0;
    data->prev_report[5] = 0;
    data->prev_report[6] = 0;
    data->prev_report[7] = 0;

    /*
     * CRITICAL: HID Device Initialization
     * This is copied EXACTLY from the working usb_keyboard.c
     * Without this, many devices won't send reports!
     */

    /* Step 1: Set USB configuration */
    grub_usb_set_configuration(usbdev, configno + 1);

    /* Step 2: Set HID protocol to boot mode (0)
     * This tells the device to use simplified 8-byte reports */
    grub_usb_control_msg(usbdev,
                         GRUB_USB_REQTYPE_CLASS_INTERFACE_OUT,
                         USB_HID_SET_PROTOCOL,
                         0,       /* 0 = boot protocol */
                         interfno,
                         0, 0);

    /* Step 3: Set idle rate to 0
     * This means: only send reports when something changes */
    grub_usb_control_msg(usbdev,
                         GRUB_USB_REQTYPE_CLASS_INTERFACE_OUT,
                         USB_HID_SET_IDLE,
                         0 << 8,  /* Idle rate = 0 (infinite) */
                         interfno,
                         0, 0);

    grub_dprintf("usb_snes", "HID initialization complete\n");

    /* Setup terminal */
    grub_usb_snes_terms[curnum].name = grub_xasprintf("usb_snes%d", curnum);
    grub_usb_snes_terms[curnum].getkey = grub_usb_snes_getkey;
    grub_usb_snes_terms[curnum].getkeystatus = grub_usb_snes_getkeystatus;
    grub_usb_snes_terms[curnum].data = data;
    grub_usb_snes_terms[curnum].next = 0;

    if (!grub_usb_snes_terms[curnum].name)
    {
        grub_print_error();
        grub_free(data);
        return 0;
    }

    /* Set detach hook */
    usbdev->config[configno].interf[interfno].detach_hook = grub_usb_snes_detach;

    /* Start background reading */
    data->transfer = grub_usb_bulk_read_background(
        usbdev,
        data->endp,
        sizeof(data->report),
        (char *)data->report);

    if (!data->transfer)
    {
        grub_print_error();
        grub_free((char *)grub_usb_snes_terms[curnum].name);
        grub_free(data);
        grub_usb_snes_terms[curnum].data = NULL;
        return 0;
    }

    /* Register terminal */
    grub_term_register_input_active("usb_snes", &grub_usb_snes_terms[curnum]);

    grub_printf("SNES gamepad %d connected! (VID=%04x PID=%04x)\n",
                curnum, usbdev->descdev.vendorid, usbdev->descdev.prodid);

    return 1;
}

/* USB attach hook - we hook into HID class like keyboard does */
static struct grub_usb_attach_desc attach_hook =
{
    .class = GRUB_USB_CLASS_HID,
    .hook = grub_usb_snes_attach
};

GRUB_MOD_INIT(usb_snes)
{
    grub_dprintf("usb_snes", "USB SNES module loaded\n");
    grub_usb_register_attach_hook_class(&attach_hook);
}

GRUB_MOD_FINI(usb_snes)
{
    unsigned i;
    for (i = 0; i < MAX_GAMEPADS; i++)
    {
        struct grub_usb_snes_data *data = grub_usb_snes_terms[i].data;
        if (!data)
            continue;

        if (data->transfer)
            grub_usb_cancel_transfer(data->transfer);

        grub_term_unregister_input(&grub_usb_snes_terms[i]);
        grub_free((char *)grub_usb_snes_terms[i].name);
        grub_usb_snes_terms[i].name = NULL;
        grub_free(data);
        grub_usb_snes_terms[i].data = NULL;
    }
    grub_usb_unregister_attach_hook_class(&attach_hook);
    grub_dprintf("usb_snes", "USB SNES module unloaded\n");
}
