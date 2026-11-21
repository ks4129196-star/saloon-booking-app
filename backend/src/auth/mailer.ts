import nodemailer, { type Transporter } from 'nodemailer';

import { config } from '../config.js';
import { CodePurpose } from '../generated/prisma/enums.js';

export interface Mailer {
  sendCode(to: string, code: string, purpose: CodePurpose): Promise<void>;
}

/** Sends codes over SMTP (Resend, Brevo, Gmail, ...). */
class SmtpMailer implements Mailer {
  private readonly transport: Transporter;

  constructor(smtp: NonNullable<typeof config.smtp>) {
    this.transport = nodemailer.createTransport({
      host: smtp.host,
      port: smtp.port,
      secure: smtp.port === 465,
      auth: smtp.user ? { user: smtp.user, pass: smtp.password } : undefined,
    });
  }

  async sendCode(to: string, code: string, purpose: CodePurpose) {
    const subject =
      purpose === CodePurpose.signup ? 'Confirm your Salon Finder account' : 'Your Salon Finder login code';
    const intro =
      purpose === CodePurpose.signup ? 'Your verification code is:' : 'Your login code is:';
    await this.transport.sendMail({
      from: config.mailFrom,
      to,
      subject,
      text: `${intro} ${code}\n\nIt expires in 10 minutes. If you did not request it, ignore this email.`,
      html:
        `<p>${intro}</p>` +
        `<p style="font-size:28px;font-weight:700;letter-spacing:6px">${code}</p>` +
        '<p>It expires in 10 minutes. If you did not request it, ignore this email.</p>',
    });
  }
}

/** Development only: prints codes to the server log instead of emailing. */
class ConsoleMailer implements Mailer {
  async sendCode(to: string, code: string, purpose: CodePurpose) {
    console.log(`[dev mail] ${purpose} code for ${to}: ${code}`);
  }
}

let mailer: Mailer = config.smtp ? new SmtpMailer(config.smtp) : new ConsoleMailer();

export const getMailer = () => mailer;

/** Tests swap in a mailer that records codes. */
export const setMailer = (replacement: Mailer) => {
  mailer = replacement;
};
