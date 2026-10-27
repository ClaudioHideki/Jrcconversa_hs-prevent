/* global axios */
import ApiClient from '../ApiClient';

class FluxChannel extends ApiClient {
  constructor() {
    super('channels/flux', { accountScoped: true });
  }

  testConnection(data) {
    return axios.post(`${this.url}/test_connection`, data);
  }
}

export default new FluxChannel();
