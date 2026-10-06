import nodemailer from 'nodemailer';
import { getEnv } from '../utils/env';
import { logger } from '../utils/logger';

export async function sendInviteEmail(message: {
  email: string;
  fullName: string;
  shopName: string;
  link: string;
  expiresAt: string;
}): Promise<boolean> {
  const env = getEnv();
  if (!env.SMTP_URL) {
    logger.info('invite email skipped');
    return false;
  }
  const date = new Date(message.expiresAt);
  const format = (locale: string) =>
    new Intl.DateTimeFormat(locale, {
      timeZone: 'Africa/Cairo',
      dateStyle: 'full',
      timeStyle: 'short',
    }).format(date);
  await nodemailer.createTransport(env.SMTP_URL).sendMail({
    from: env.MAIL_FROM,
    to: message.email,
    subject: `دعوة إلى ${message.shopName} / Invitation to ${message.shopName}`,
    text: `مرحباً ${message.fullName}\nتمت دعوتك إلى ${message.shopName}.\nافتح الرابط لتعيين كلمة المرور أو أدخل كلمة مرور حسابك الحالي:\n${message.link}\nتنتهي الدعوة في ${format('ar-EG')} (توقيت القاهرة).\n\nHello ${message.fullName},\nYou are invited to ${message.shopName}.\nOpen the link to set your password or enter your existing account password:\n${message.link}\nThis invitation expires on ${format('en-GB')} (Cairo time).`,
  });
  return true;
}
